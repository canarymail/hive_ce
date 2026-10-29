import 'dart:math';

import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/frame.dart';
import 'package:hive_ce/src/box/change_notifier.dart';
import 'package:hive_ce/src/box/keystore.dart';
import 'package:test/test.dart';

(Object, int, int?) describe(Frame frame) =>
    (frame.key, frame.offset, frame.length);

(Object?, bool, Object?) describeEvent(BoxEvent event) =>
    (event.key, event.deleted, event.value);

void main() {
  group('Keystore(lazy: true)', () {
    test('stores frames lazily, dropping values', () {
      final actualKeystore = Keystore.debug(lazy: true);

      actualKeystore.insert(Frame('a', 'value', length: 5, offset: 3));

      final actualFrame = actualKeystore.get('a')!;
      expect(actualFrame.lazy, isTrue);
      expect(actualFrame.value, isNull);
      expect(describe(actualFrame), ('a', 3, 5));
    });

    test('keeps the auto increment of int keys', () {
      final actualKeystore = Keystore.debug(lazy: true);

      actualKeystore.insert(Frame.lazy(41, offset: 0, length: 1));

      expect(actualKeystore.autoIncrement(), 42);
    });

    test('.clear() reports and resets like the skip list keystore', () async {
      final inputFrames = [
        for (var i = 0; i < 400; i++) Frame.lazy('k$i', offset: i, length: 1),
      ];
      final notifier = ChangeNotifier();
      final actualEvents = <BoxEvent>[];
      notifier.watch().listen(actualEvents.add);
      final actualKeystore =
          Keystore.debug(frames: inputFrames, notifier: notifier, lazy: true);
      await pumpEventQueue();
      actualEvents.clear();

      final actualCleared = actualKeystore.clear();
      await pumpEventQueue();

      expect(actualCleared, 400);
      expect(actualKeystore.length, 0);
      expect(actualKeystore.deletedEntries, 0);
      expect(actualKeystore.autoIncrement(), 0);
      expect(actualEvents.length, 400);
      expect(actualEvents.every((e) => e.deleted), isTrue);
    });

    /// Feeds the same stream of frames, as a lazy box's file and writes
    /// would, to a skip-list keystore and a compact one.
    Future<void> runDifferential(int seed) async {
      final random = Random(seed);
      final expectedNotifier = ChangeNotifier();
      final actualNotifier = ChangeNotifier();
      final expectedEvents = <BoxEvent>[];
      final actualEvents = <BoxEvent>[];
      expectedNotifier.watch().listen(expectedEvents.add);
      actualNotifier.watch().listen(actualEvents.add);
      final expectedKeystore = Keystore.debug(notifier: expectedNotifier);
      final actualKeystore =
          Keystore.debug(notifier: actualNotifier, lazy: true);

      var fileOffset = 0;
      for (var i = 0; i < 6000; i++) {
        final key = random.nextInt(3) == 0
            ? random.nextInt(800) as Object
            : 'key${random.nextInt(1500)}';
        final notify = random.nextInt(4) != 0;
        final Frame frame;
        if (random.nextInt(4) == 0) {
          frame = Frame.deleted(key);
        } else {
          final length = 8 + random.nextInt(64);
          frame = Frame.lazy(key, offset: fileOffset, length: length);
          fileOffset += length;
        }

        final expectedOld = expectedKeystore.insert(
          frame,
          notify: notify,
          lazy: true,
        );
        final actualOld = actualKeystore.insert(frame, notify: notify);

        expect(actualOld == null, expectedOld == null);
        if (expectedOld != null) {
          expect(describe(actualOld!), describe(expectedOld));
        }
      }
      await pumpEventQueue();

      expect(actualKeystore.length, expectedKeystore.length);
      expect(actualKeystore.deletedEntries, expectedKeystore.deletedEntries);
      expect(
        actualKeystore.getKeys().toList(),
        expectedKeystore.getKeys().toList(),
      );
      expect(
        actualKeystore.frames.map(describe).toList(),
        expectedKeystore.frames.map(describe).toList(),
      );
      for (var i = 0; i < expectedKeystore.length; i += 37) {
        expect(actualKeystore.keyAt(i), expectedKeystore.keyAt(i));
        expect(
          describe(actualKeystore.getAt(i)!),
          describe(expectedKeystore.getAt(i)!),
        );
      }
      expect(
        actualEvents.map(describeEvent).toList(),
        expectedEvents.map(describeEvent).toList(),
      );
      expect(actualKeystore.autoIncrement(), expectedKeystore.autoIncrement());
    }

    for (final seed in [1, 2, 3]) {
      test('behaves like the skip list keystore, seed $seed', () async {
        await runDifferential(seed);
      });
    }
  });
}
