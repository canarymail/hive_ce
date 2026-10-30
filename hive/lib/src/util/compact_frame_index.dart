import 'dart:collection';
import 'dart:typed_data';

import 'package:hive_ce/src/binary/frame.dart';
import 'package:hive_ce/src/util/key_index.dart';

/// Not part of public API
///
/// The key index of a lazy box. A lazy box keeps only where each value sits
/// in the file, so every entry is a key, an offset and a length. The skip
/// list holds those as five objects per key (a node, its two level lists, a
/// [Frame] and the key) at ~230 bytes; this holds them in sorted parallel
/// arrays at ~16 bytes plus the key.
///
/// Writes land in a small sorted buffer ([_pending]) that is merged into the
/// arrays once it outgrows an eighth of them, so loading a box (one insert
/// per frame in file order) costs O(n log n), not one array shift per key.
///
/// [Frame]s are made on demand. The ones it hands out write a changed
/// [Frame.offset] back into the index: compaction moves frames in the file
/// by setting the offset on the frames it was given. The skip list hands out
/// the frame it stores, so a frame from [get] also sees compaction move it;
/// [get] returns a [_LiveFrame] that looks its key up when read for that.
class CompactFrameIndex implements KeyIndex<dynamic, Frame> {
  static const _minPendingToMerge = 256;

  /// `Int64List` is not supported when compiled to JavaScript.
  static const _isJs = identical(0, 0.0);

  final int Function(dynamic, dynamic) _comparator;

  /// Merged entries, sorted by key.
  var _keys = <Object>[];

  /// Offset of each merged entry; -1 if the frame has not been written.
  var _offsets = _newOffsets(0);

  /// Length + 1 of each merged entry; 0 if the frame has no length.
  var _lengths = Uint32List(0);

  /// Writes not merged yet: a frame, or null for a merged key deleted since.
  late final _pending = SplayTreeMap<dynamic, Frame?>(_comparator);

  var _length = 0;

  /// Not part of public API
  CompactFrameIndex(this._comparator);

  @override
  int get length => _length;

  /// Like the skip list's, the iterables below are live views: each
  /// iteration reads the index as it is when the iteration starts. Callers
  /// rely on that; compaction is handed [values] and walks it only once its
  /// turn on the file comes, after the writes queued before it.
  @override
  Iterable<dynamic> get keys => _KeyIterable(this);

  @override
  Iterable<Frame> get values => _FrameIterable(this, null);

  static List<int> _newOffsets(int length) =>
      _isJs ? List<int>.filled(length, 0) : Int64List(length);

  @override
  Frame? get(dynamic key) {
    final frame = _snapshot(key);
    return frame == null ? null : _LiveFrame(this, frame);
  }

  /// The entry for [key] as it is now.
  Frame? _snapshot(dynamic key) {
    if (_pending.containsKey(key)) return _pending[key];
    final index = _indexOf(key);
    return index < 0 ? null : _frameAt(index);
  }

  @override
  Frame? insert(dynamic key, Frame? value) {
    if (value == null) return delete(key);
    // A live frame stored here would look itself up.
    if (value is _LiveFrame) {
      value = Frame.lazy(key, length: value.length, offset: value.offset);
    }
    final old = _snapshot(key);
    _pending[key] = value;
    if (old == null) _length++;
    _mergeIfLarge();
    return old;
  }

  @override
  Frame? delete(dynamic key) {
    final old = _snapshot(key);
    if (old == null) return null;
    if (_indexOf(key) >= 0) {
      _pending[key] = null;
    } else {
      _pending.remove(key);
    }
    _length--;
    _mergeIfLarge();
    return old;
  }

  @override
  Iterable<Frame> valuesFromKey(dynamic key) => _FrameIterable(this, key);

  @override
  Frame? getAt(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    _merge();
    return _frameAt(index);
  }

  @override
  dynamic getKeyAt(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    _merge();
    return _keys[index];
  }

  @override
  void clear() {
    _keys = <Object>[];
    _offsets = _newOffsets(0);
    _lengths = Uint32List(0);
    _pending.clear();
    _length = 0;
  }

  Frame _frameAt(int index) => _IndexedFrame(
        this,
        _keys[index],
        length: _lengths[index] == 0 ? null : _lengths[index] - 1,
        offset: _offsets[index],
      );

  /// The index of [key] among the merged entries, or -1.
  int _indexOf(dynamic key) {
    var low = 0;
    var high = _keys.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final cmp = _comparator(_keys[mid], key);
      if (cmp < 0) {
        low = mid + 1;
      } else if (cmp > 0) {
        high = mid - 1;
      } else {
        return mid;
      }
    }
    return -1;
  }

  void _mergeIfLarge() {
    final threshold = _keys.length >> 3;
    if (_pending.length > _minPendingToMerge && _pending.length > threshold) {
      _merge();
    }
  }

  /// Folds [_pending] into the arrays. Builds new arrays rather than editing
  /// them in place, so an iteration already under way keeps a stable
  /// snapshot.
  void _merge() {
    if (_pending.isEmpty) return;

    // Exactly sized: a growable list would carry up to 2x slack.
    final keys = List<Object>.filled(_length, 0);
    final offsets = _newOffsets(_length);
    final lengths = Uint32List(_length);
    var out = 0;

    void add(Object key, int offset, int lengthPlusOne) {
      keys[out] = key;
      offsets[out] = offset;
      lengths[out] = lengthPlusOne;
      out++;
    }

    void addFrame(Object key, Frame frame) {
      final length = frame.length;
      add(key, frame.offset, length == null ? 0 : length + 1);
    }

    var i = 0;
    final merged = _keys.length;
    for (final entry in _pending.entries) {
      final key = entry.key as Object;
      while (i < merged && _comparator(_keys[i], key) < 0) {
        add(_keys[i], _offsets[i], _lengths[i]);
        i++;
      }
      if (i < merged && _comparator(_keys[i], key) == 0) {
        // Replaced or deleted since the last merge.
        i++;
      }
      final frame = entry.value;
      if (frame != null) addFrame(key, frame);
    }
    while (i < merged) {
      add(_keys[i], _offsets[i], _lengths[i]);
      i++;
    }

    assert(out == _length, 'merged $out entries, expected $_length');
    _keys = keys;
    _offsets = offsets;
    _lengths = lengths;
    _pending.clear();
  }

  /// Moves [key] from [oldOffset] to [newOffset], if it is still the frame
  /// that was at [oldOffset] (a newer write of the key is left alone).
  void _updateOffset(dynamic key, int oldOffset, int newOffset) {
    if (_pending.containsKey(key)) {
      final frame = _pending[key];
      if (frame != null && frame.offset == oldOffset) {
        frame.offset = newOffset;
      }
      return;
    }
    final index = _indexOf(key);
    if (index >= 0 && _offsets[index] == oldOffset) {
      _offsets[index] = newOffset;
    }
  }
}

/// A frame read out of a [CompactFrameIndex] that writes a changed offset
/// back into it.
///
/// Compaction is handed these through [CompactFrameIndex.values].
class _IndexedFrame extends Frame {
  final CompactFrameIndex _index;

  _IndexedFrame(this._index, super.key, {super.length, super.offset})
      : super.lazy();

  @override
  set offset(int value) {
    final old = super.offset;
    super.offset = value;
    if (old != value) _index._updateOffset(key, old, value);
  }
}

/// A frame from [CompactFrameIndex.get]. A lazy box reads its value only
/// once the read's turn on the file comes, possibly after a compaction moved
/// it, so this reads its offset and length from the index when asked.
///
/// If the key has since been written again, that is the newer value; if it
/// has been deleted, this keeps the offset it was handed out with, as the
/// skip list's frame would.
class _LiveFrame extends Frame {
  final CompactFrameIndex _index;

  _LiveFrame(this._index, Frame frame)
      : super.lazy(frame.key, length: frame.length, offset: frame.offset);

  Frame? get _current => _index._snapshot(key);

  @override
  int get offset => _current?.offset ?? super.offset;

  /// Writes back only over the entry it was handed out for.
  @override
  set offset(int value) {
    final old = super.offset;
    super.offset = value;
    if (old != value) _index._updateOffset(key, old, value);
  }

  @override
  int? get length {
    final current = _current;
    return current == null ? super.length : current.length;
  }
}

class _KeyIterable extends IterableBase<dynamic> {
  final CompactFrameIndex _index;

  _KeyIterable(this._index);

  @override
  int get length => _index.length;

  @override
  Iterator<dynamic> get iterator {
    _index._merge();
    return _index._keys.iterator;
  }
}

class _FrameIterable extends IterableBase<Frame> {
  final CompactFrameIndex _index;

  /// The key to start from, or null to start at the first entry.
  final Object? _startKey;

  _FrameIterable(this._index, this._startKey);

  @override
  Iterator<Frame> get iterator {
    final index = _index.._merge();
    final startKey = _startKey;
    final start = startKey == null ? 0 : index._indexOf(startKey);
    return _FrameIterator(
      index,
      index._keys,
      index._offsets,
      index._lengths,
      start < 0 ? index._keys.length : start,
    );
  }
}

class _FrameIterator implements Iterator<Frame> {
  final CompactFrameIndex _index;
  final List<Object> _keys;
  final List<int> _offsets;
  final Uint32List _lengths;
  int _next;
  Frame? _current;

  _FrameIterator(
    this._index,
    this._keys,
    this._offsets,
    this._lengths,
    this._next,
  );

  @override
  Frame get current => _current!;

  @override
  bool moveNext() {
    if (_next >= _keys.length) {
      _current = null;
      return false;
    }
    final length = _lengths[_next];
    _current = _IndexedFrame(
      _index,
      _keys[_next],
      length: length == 0 ? null : length - 1,
      offset: _offsets[_next],
    );
    _next++;
    return true;
  }
}
