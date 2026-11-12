import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/backend/lock_props.dart';
import 'package:hive_ce/src/backend/storage_backend.dart';
import 'package:hive_ce/src/backend/vm/read_write_sync.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:hive_ce/src/binary/frame.dart';
import 'package:hive_ce/src/box/keystore.dart';
import 'package:hive_ce/src/io/buffered_file_reader.dart';
import 'package:hive_ce/src/io/buffered_file_writer.dart';
import 'package:hive_ce/src/io/frame_io_helper.dart';
import 'package:hive_ce/src/registry/type_registry_impl.dart';
import 'package:hive_ce/src/util/debug_utils.dart';
import 'package:meta/meta.dart';

/// Storage backend for the Dart VM
class StorageBackendVm extends StorageBackend {
  /// Warning for existing lock of unmatched isolation
  @visibleForTesting
  static const unmatchedIsolationWarning = '''
⚠️ WARNING: HIVE MULTI-ISOLATE RISK DETECTED ⚠️

You are opening this box with Hive, but this box was previously opened with
IsolatedHive. This can lead to DATA CORRUPTION as Hive boxes are not designed
for concurrent access across isolates. Each isolate would maintain its own box
cache, potentially causing data inconsistency and corruption.

RECOMMENDED ACTIONS:
- ALWAYS use IsolatedHive to perform box operations when working with multiple
  isolates
''';

  final File _file;
  final File _lockFile;
  final bool _crashRecovery;
  final HiveCipher? _cipher;
  final FrameIoHelper _frameHelper;

  final ReadWriteSync _sync;

  /// Not part of public API
  ///
  /// Not `late final` for testing
  @visibleForTesting
  late RandomAccessFile readRaf;

  /// Not part of public API
  ///
  /// Not `late final` for testing
  @visibleForTesting
  late RandomAccessFile writeRaf;

  /// Not part of public API
  @visibleForTesting
  late RandomAccessFile lockRaf;

  /// Not part of public API
  @visibleForTesting
  var writeOffset = 0;

  /// Not part of public API
  @visibleForTesting
  late final TypeRegistry registry;

  var _compactionScheduled = false;

  /// Not part of public API
  StorageBackendVm(
    this._file,
    this._lockFile,
    this._crashRecovery,
    this._cipher,
  )   : _frameHelper = FrameIoHelper(),
        _sync = ReadWriteSync();

  /// Not part of public API
  StorageBackendVm.debug(
    this._file,
    this._lockFile,
    this._crashRecovery,
    this._cipher,
    this._frameHelper,
    this._sync,
  );

  @override
  String get path => _file.path;

  @override
  var supportsCompaction = true;

  /// Not part of public API
  Future open() async {
    readRaf = await _file.open();
    writeRaf = await _file.open(mode: FileMode.writeOnlyAppend);
    writeOffset = await writeRaf.length();
  }

  @override
  Future<void> initialize(
    TypeRegistry registry,
    Keystore keystore,
    bool lazy, {
    bool isolated = false,
  }) async {
    this.registry = registry;

    if (_lockFile.existsSync()) {
      late final LockProps props;
      try {
        props = LockProps.fromJson(jsonDecode(_lockFile.readAsStringSync()));
      } catch (_) {
        props = LockProps();
      }
      if (props.isolated && !isolated) {
        debugPrint(unmatchedIsolationWarning);
      }
    }

    lockRaf = await _lockFile.open(mode: FileMode.write);
    lockRaf.writeStringSync(jsonEncode(LockProps(isolated: isolated)));
    lockRaf.flushSync();
    await lockRaf.lock();

    int? recoveryOffset;
    if (_frameHelper.runtimeType == FrameIoHelper) {
      recoveryOffset = await _readOffIsolate(
        registry,
        keystore,
        lazy,
        verbatim: isolated,
      );
    }
    if (recoveryOffset == null) {
      if (!lazy) {
        recoveryOffset = await _frameHelper.framesFromFile(
          path,
          keystore,
          registry,
          _cipher,
          verbatim: isolated,
        );
      } else {
        recoveryOffset =
            await _frameHelper.keysFromFile(path, keystore, _cipher);
      }
    }

    if (recoveryOffset != -1) {
      if (_crashRecovery) {
        debugPrint('Recovering corrupted box.');
        await writeRaf.truncate(recoveryOffset);
        await writeRaf.setPosition(recoveryOffset);
        writeOffset = recoveryOffset;
      } else {
        throw HiveError('Wrong checksum in hive file. Box may be corrupted.');
      }
    }
  }

  /// Reads the file into [keystore] on another isolate, so opening a box
  /// costs this isolate next to nothing: decoding every frame of a large box
  /// took hundreds of milliseconds of it, which on the UI isolate stalls the
  /// app. The index is built there and handed back without a copy
  /// ([Isolate.exit]). Returns the recovery offset as the in-isolate read
  /// does, or null when it could not run here (the caller reads the file on
  /// this isolate instead). A file nothing was written to yet is read here.
  Future<int?> _readOffIsolate(
    TypeRegistry registry,
    Keystore keystore,
    bool lazy, {
    required bool verbatim,
  }) async {
    if (writeOffset < _minOffIsolateBytes) return null;
    final spec = keystore.detachedSpec;
    if (spec.lazy != lazy) return null;
    // Locals only: a closure that read a field would capture this backend,
    // whose open files cannot be sent to another isolate.
    final filePath = path;
    final cipher = _cipher;
    // A lazy box decodes no values.
    final adapters = lazy
        ? TypeRegistryImpl.nullImpl
        : registry is TypeRegistryImpl
            ? registry.adaptersOnly()
            : null;
    if (adapters == null) return null;
    try {
      final read = await Isolate.run(
        () => _readDetached(filePath, spec, adapters, cipher, verbatim),
        debugName: 'hive open',
      );
      keystore.adopt(read.keys);
      return read.recoveryOffset;
    } catch (e) {
      debugPrint('Hive: reading $path off the isolate failed ($e); '
          'reading it here.');
      return null;
    }
  }

  /// Smaller files are read on the box's isolate: starting an isolate costs
  /// more than reading them.
  static const _minOffIsolateBytes = 64 * 1024;

  static Future<({int recoveryOffset, DetachedKeys keys})> _readDetached(
    String path,
    ({KeyComparator? keyComparator, bool lazy}) spec,
    TypeRegistry registry,
    HiveCipher? cipher,
    bool verbatim,
  ) async {
    final keystore = Keystore.detached<dynamic>(spec);
    final helper = FrameIoHelper();
    final recoveryOffset = spec.lazy
        ? await helper.keysFromFile(path, keystore, cipher)
        : await helper.framesFromFile(
            path,
            keystore,
            registry,
            cipher,
            verbatim: verbatim,
          );
    return (recoveryOffset: recoveryOffset, keys: keystore.detachedKeys);
  }

  @override
  Future<dynamic> readValue(Frame frame, {bool verbatim = false}) {
    return _sync.syncRead(() async {
      // Read both before the first await: a lazy box's frame can follow its
      // key to a newer write.
      final offset = frame.offset;
      final length = frame.length!;
      await readRaf.setPosition(offset);

      final bytes = await readRaf.read(length);

      final reader = BinaryReaderImpl(bytes, registry);
      final readFrame =
          reader.readFrame(cipher: _cipher, lazy: false, verbatim: verbatim);

      if (readFrame == null) {
        throw HiveError(
          'Could not read value from box. Maybe your box is corrupted.',
        );
      }

      return readFrame.value;
    });
  }

  @override
  Future<void> writeFrames(List<Frame> frames, {bool verbatim = false}) {
    return _sync.syncWrite(() async {
      final writer = BinaryWriterImpl(registry);

      for (final frame in frames) {
        frame.length =
            writer.writeFrame(frame, cipher: _cipher, verbatim: verbatim);
      }

      try {
        await writeRaf.writeFrom(writer.toBytes());
      } catch (e) {
        await writeRaf.setPosition(writeOffset);
        rethrow;
      }

      for (final frame in frames) {
        frame.offset = writeOffset;
        writeOffset += frame.length!;
      }
    });
  }

  @override
  Future<void> compact(Iterable<Frame> frames) {
    if (_compactionScheduled) return Future.value();
    _compactionScheduled = true;

    return _sync.syncReadWrite(() async {
      await readRaf.setPosition(0);
      final reader = BufferedFileReader(readRaf);

      final fileDirectory = path.substring(0, path.length - 5);
      final compactFile = File('$fileDirectory.hivec');
      final compactRaf = await compactFile.open(mode: FileMode.write);
      final writer = BufferedFileWriter(compactRaf);

      final sortedFrames = frames.toList();
      sortedFrames.sort((a, b) => a.offset.compareTo(b.offset));
      try {
        for (final frame in sortedFrames) {
          if (frame.offset == -1) continue; // Frame has not been written yet
          if (frame.offset != reader.offset) {
            final skip = frame.offset - reader.offset;
            if (reader.remainingInBuffer < skip) {
              if (await reader.loadBytes(skip) < skip) {
                throw HiveError('Could not compact box: Unexpected EOF.');
              }
            }
            reader.skip(skip);
          }

          if (reader.remainingInBuffer < frame.length!) {
            if (await reader.loadBytes(frame.length!) < frame.length!) {
              throw HiveError('Could not compact box: Unexpected EOF.');
            }
          }
          await writer.write(reader.viewBytes(frame.length!));
        }
        await writer.flush();
      } finally {
        await compactRaf.close();
      }

      await readRaf.close();
      await writeRaf.close();

      try {
        // This can fail on some systems
        await compactFile.rename(path);
      } catch (e) {
        await compactFile.delete();
        rethrow;
      } finally {
        await open();
        _compactionScheduled = false;
      }

      var offset = 0;
      for (final frame in sortedFrames) {
        if (frame.offset == -1) continue;
        frame.offset = offset;
        offset += frame.length!;
      }
    });
  }

  @override
  Future<void> clear() {
    return _sync.syncReadWrite(() async {
      await writeRaf.truncate(0);
      await writeRaf.setPosition(0);
      writeOffset = 0;
    });
  }

  Future _closeInternal() async {
    await readRaf.close();
    await writeRaf.close();

    await lockRaf.close();
    await _lockFile.delete();
  }

  @override
  Future<void> close() {
    return _sync.syncReadWrite(_closeInternal);
  }

  @override
  Future<void> deleteFromDisk() {
    return _sync.syncReadWrite(() async {
      await _closeInternal();
      await _file.delete();
    });
  }

  @override
  Future<void> flush() {
    return _sync.syncWrite(() async {
      await writeRaf.flush();
    });
  }
}
