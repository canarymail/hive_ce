import 'dart:math';

import 'package:hive_ce/src/binary/frame.dart';
import 'package:hive_ce/src/box/default_key_comparator.dart';
import 'package:hive_ce/src/util/compact_frame_index.dart';
import 'package:hive_ce/src/util/indexable_skip_list.dart';
import 'package:test/test.dart';

/// A lazy frame as the index stores it: key, offset, length.
Frame lazyFrame(Object key, {int offset = 0, int? length = 10}) =>
    Frame.lazy(key, offset: offset, length: length);

/// What a frame means to a lazy box, without identity.
(Object, int, int?) describe(Frame frame) =>
    (frame.key, frame.offset, frame.length);

void main() {
  group('CompactFrameIndex', () {
    late CompactFrameIndex actualIndex;

    setUp(() {
      actualIndex = CompactFrameIndex(defaultKeyComparator);
    });

    test('starts empty', () {
      expect(actualIndex.length, 0);
      expect(actualIndex.keys, isEmpty);
      expect(actualIndex.values, isEmpty);
      expect(actualIndex.get('missing'), isNull);
      expect(actualIndex.valuesFromKey('missing'), isEmpty);
    });

    test('.insert() stores key, offset and length', () {
      final inputFrame = lazyFrame('a', offset: 42, length: 7);

      final actualOld = actualIndex.insert('a', inputFrame);

      expect(actualOld, isNull);
      expect(actualIndex.length, 1);
      expect(describe(actualIndex.get('a')!), ('a', 42, 7));
    });

    test('.insert() returns the replaced frame and keeps the length', () {
      actualIndex.insert('a', lazyFrame('a', offset: 1));

      final actualOld = actualIndex.insert('a', lazyFrame('a', offset: 2));

      expect(describe(actualOld!), ('a', 1, 10));
      expect(actualIndex.length, 1);
      expect(actualIndex.get('a')!.offset, 2);
    });

    test('.delete() removes pending and merged keys', () {
      for (var i = 0; i < 1000; i++) {
        actualIndex.insert('k$i', lazyFrame('k$i', offset: i));
      }
      // Forces everything into the arrays.
      actualIndex.keys.toList();
      actualIndex.insert('fresh', lazyFrame('fresh'));

      final actualMerged = actualIndex.delete('k5');
      final actualPending = actualIndex.delete('fresh');
      final actualMissing = actualIndex.delete('nope');

      expect(describe(actualMerged!), ('k5', 5, 10));
      expect(actualPending!.key, 'fresh');
      expect(actualMissing, isNull);
      expect(actualIndex.length, 999);
      expect(actualIndex.get('k5'), isNull);
      expect(actualIndex.get('fresh'), isNull);
      expect(actualIndex.keys.contains('k5'), isFalse);
    });

    test('.insert() with a null value deletes the key', () {
      actualIndex.insert('a', lazyFrame('a'));

      actualIndex.insert('a', null);

      expect(actualIndex.length, 0);
      expect(actualIndex.get('a'), isNull);
    });

    test('keeps a null length and an unwritten offset', () {
      actualIndex.insert('a', Frame.lazy('a'));

      expect(describe(actualIndex.get('a')!), ('a', -1, null));
      expect(describe(actualIndex.values.single), ('a', -1, null));
    });

    test('keeps large offsets and lengths', () {
      const inputOffset = 0x1FFFFFFFF;
      const inputLength = 0xFFFFFFFE;
      actualIndex.insert(
        'a',
        lazyFrame('a', offset: inputOffset, length: inputLength),
      );

      expect(
        describe(actualIndex.values.single),
        ('a', inputOffset, inputLength),
      );
    });

    test('orders int keys before string keys, like the skip list', () {
      final inputKeys = <Object>['b', 3, 'a', 1, 'aa', 2, 0xFFFFFFFF, ''];
      for (final key in inputKeys) {
        actualIndex.insert(key, lazyFrame(key));
      }

      expect(
        actualIndex.keys.toList(),
        [1, 2, 3, 0xFFFFFFFF, '', 'a', 'aa', 'b'],
      );
    });

    test('follows a custom key comparator', () {
      final reversed = CompactFrameIndex((a, b) => defaultKeyComparator(b, a));
      for (var i = 0; i < 600; i++) {
        reversed.insert(i, lazyFrame(i));
      }

      expect(reversed.keys.first, 599);
      expect(reversed.getKeyAt(599), 0);
      expect(reversed.get(300)!.key, 300);
    });

    test('.getAt() and .getKeyAt() index in key order', () {
      for (final key in ['c', 'a', 'b']) {
        actualIndex.insert(key, lazyFrame(key, offset: key.codeUnitAt(0)));
      }

      expect(actualIndex.getKeyAt(0), 'a');
      expect(actualIndex.getAt(2)!.key, 'c');
      expect(actualIndex.getAt(1)!.offset, 'b'.codeUnitAt(0));
      expect(() => actualIndex.getAt(3), throwsRangeError);
      expect(() => actualIndex.getKeyAt(-1), throwsRangeError);
    });

    test('.valuesFromKey() starts at the key, and is empty for a missing key',
        () {
      for (var i = 0; i < 10; i++) {
        actualIndex.insert(i, lazyFrame(i));
      }

      expect(actualIndex.valuesFromKey(7).map((f) => f.key), [7, 8, 9]);
      expect(actualIndex.valuesFromKey(42), isEmpty);
    });

    test('.clear() empties the index', () {
      for (var i = 0; i < 500; i++) {
        actualIndex.insert(i, lazyFrame(i));
      }

      actualIndex.clear();

      expect(actualIndex.length, 0);
      expect(actualIndex.keys, isEmpty);
      expect(actualIndex.get(1), isNull);
      actualIndex.insert(1, lazyFrame(1));
      expect(actualIndex.keys, [1]);
    });

    group('live iterables', () {
      test('.values and .keys read the index when iteration starts', () {
        final inputValues = actualIndex.values;
        final inputKeys = actualIndex.keys;
        actualIndex.insert('a', lazyFrame('a'));
        actualIndex.insert('b', lazyFrame('b'));

        expect(inputValues.map((f) => f.key), ['a', 'b']);
        expect(inputKeys, ['a', 'b']);
        expect(inputKeys.length, 2);

        actualIndex.delete('a');

        expect(inputValues.map((f) => f.key), ['b']);
        expect(inputKeys, ['b']);
      });

      test('an iteration under way keeps its snapshot through a merge', () {
        for (var i = 0; i < 2000; i++) {
          actualIndex.insert(i, lazyFrame(i, offset: i));
        }
        final actualSeen = <dynamic>[];

        for (final frame in actualIndex.values) {
          actualSeen.add(frame.key);
          if (frame.key == 10) {
            // Enough writes to merge again mid-iteration.
            for (var i = 5000; i < 7000; i++) {
              actualIndex.insert(i, lazyFrame(i));
            }
            actualIndex.delete(1500);
          }
        }

        expect(actualSeen, List.generate(2000, (i) => i));
        expect(actualIndex.length, 3999);
      });
    });

    group('offset write-back', () {
      test('setting a handed-out frame offset updates the index', () {
        // Gaps between frames, as deleted frames leave in the file.
        for (var i = 0; i < 1000; i++) {
          actualIndex.insert(i, lazyFrame(i, offset: 7 + i * 25));
        }
        final inputFrames = actualIndex.values.toList();

        // What compaction does after rewriting the file.
        var newOffset = 0;
        for (final frame in inputFrames) {
          frame.offset = newOffset;
          newOffset += frame.length!;
        }

        for (var i = 0; i < 1000; i++) {
          expect(actualIndex.get(i)!.offset, i * 10);
        }
      });

      test('a frame from .get() and .getAt() writes back too', () {
        for (var i = 0; i < 300; i++) {
          actualIndex.insert(i, lazyFrame(i, offset: 1000 + i));
        }

        actualIndex.get(5)!.offset = 1;
        actualIndex.getAt(6)!.offset = 2;

        expect(actualIndex.get(5)!.offset, 1);
        expect(actualIndex.get(6)!.offset, 2);
      });

      test('reaches a key re-inserted and not merged yet', () {
        // A cancelled transaction puts the frame it removed back.
        for (var i = 0; i < 1000; i++) {
          actualIndex.insert(i, lazyFrame(i, offset: i));
        }
        actualIndex.keys.toList();
        final inputFrame = actualIndex.get(500)!;
        actualIndex.delete(500);
        actualIndex.insert(500, inputFrame);

        inputFrame.offset = 77;

        expect(actualIndex.get(500)!.offset, 77);
        actualIndex.keys.toList();
        expect(actualIndex.get(500)!.offset, 77);
      });

      test('a frame from a merged entry writes back while others wait', () {
        for (var i = 0; i < 1000; i++) {
          actualIndex.insert(i, lazyFrame(i, offset: i));
        }
        final inputFrame = actualIndex.values.firstWhere((f) => f.key == 42);
        actualIndex.insert('pending', lazyFrame('pending'));

        inputFrame.offset = 4242;

        expect(actualIndex.get(42)!.offset, 4242);
      });

      test('leaves a newer write of the same key alone', () {
        for (var i = 0; i < 300; i++) {
          actualIndex.insert(i, lazyFrame(i, offset: i));
        }
        final inputStale = actualIndex.get(3)!;
        actualIndex.insert(3, lazyFrame(3, offset: 9999));

        inputStale.offset = 0;

        expect(actualIndex.get(3)!.offset, 9999);
      });

      test('ignores a key deleted since the frame was handed out', () {
        actualIndex.insert('a', lazyFrame('a', offset: 4));
        final inputStale = actualIndex.get('a')!;
        actualIndex.delete('a');

        inputStale.offset = 0;

        expect(actualIndex.get('a'), isNull);
        expect(actualIndex.length, 0);
      });
    });

    group('frames from .get()', () {
      /// What compaction does: rewrites the file and moves every frame.
      void compact(CompactFrameIndex index) {
        var newOffset = 0;
        for (final frame in index.values.toList()) {
          frame.offset = newOffset;
          newOffset += frame.length!;
        }
      }

      test('follow a compaction that runs after .get()', () {
        for (var i = 0; i < 1000; i++) {
          actualIndex.insert(i, lazyFrame(i, offset: 7 + i * 25));
        }
        final inputFrame = actualIndex.get(500)!;

        compact(actualIndex);

        expect(describe(inputFrame), (500, 5000, 10));
      });

      test('follow a compaction that merges the pending entry', () {
        for (var i = 0; i < 1000; i++) {
          actualIndex.insert(i, lazyFrame(i, offset: 7 + i * 25));
        }
        actualIndex.keys.toList();
        actualIndex.insert(2000, lazyFrame(2000, offset: 99999));
        final inputFrame = actualIndex.get(2000)!;

        compact(actualIndex);

        expect(describe(inputFrame), (2000, 10000, 10));
      });

      test('read a newer write of the key', () {
        actualIndex.insert('a', lazyFrame('a', offset: 4, length: 3));
        final inputFrame = actualIndex.get('a')!;

        actualIndex.insert('a', lazyFrame('a', offset: 40, length: 30));

        expect(describe(inputFrame), ('a', 40, 30));
      });

      test('keep their offset once the key is deleted', () {
        for (var i = 0; i < 300; i++) {
          actualIndex.insert(i, lazyFrame(i, offset: 1000 + i));
        }
        final inputFrame = actualIndex.get(7)!;

        actualIndex.delete(7);
        compact(actualIndex);

        expect(describe(inputFrame), (7, 1007, 10));
      });

      test('are stored as plain frames when inserted back', () {
        actualIndex.insert('a', lazyFrame('a', offset: 4));
        final inputFrame = actualIndex.get('a')!;
        actualIndex.delete('a');

        actualIndex.insert('a', inputFrame);
        actualIndex.keys.toList();

        expect(describe(actualIndex.get('a')!), ('a', 4, 10));
      });
    });

    group('matches the skip list', () {
      /// Runs the same random operations on both and compares every read.
      void runDifferential(
        int seed, {
        required int operations,
        required int keySpace,
        int Function(dynamic, dynamic) comparator = defaultKeyComparator,
      }) {
        final random = Random(seed);
        final expectedList = IndexableSkipList<dynamic, Frame>(comparator);
        final actual = CompactFrameIndex(comparator);

        Object randomKey() => random.nextBool()
            ? random.nextInt(keySpace)
            : 'k${random.nextInt(keySpace)}';

        void compareAll() {
          expect(actual.length, expectedList.length);
          expect(actual.keys.toList(), expectedList.keys.toList());
          expect(
            actual.values.map(describe).toList(),
            expectedList.values.map(describe).toList(),
          );
          for (var i = 0; i < 20 && expectedList.length > 0; i++) {
            final index = random.nextInt(expectedList.length);
            expect(actual.getKeyAt(index), expectedList.getKeyAt(index));
            expect(
              describe(actual.getAt(index)!),
              describe(expectedList.getAt(index)!),
            );
          }
          final fromKey = randomKey();
          expect(
            actual.valuesFromKey(fromKey).map(describe).toList(),
            expectedList.valuesFromKey(fromKey).map(describe).toList(),
          );
        }

        for (var op = 0; op < operations; op++) {
          final key = randomKey();
          final roll = random.nextInt(10);
          if (roll < 6) {
            final frame = lazyFrame(
              key,
              offset: random.nextInt(1 << 20),
              length: random.nextInt(8) == 0 ? null : random.nextInt(4096),
            );
            final expectedOld = expectedList.insert(key, frame);
            final actualOld = actual.insert(key, frame);
            expect(actualOld == null, expectedOld == null);
            if (expectedOld != null) {
              expect(describe(actualOld!), describe(expectedOld));
            }
          } else if (roll < 9) {
            final expectedOld = expectedList.delete(key);
            final actualOld = actual.delete(key);
            expect(actualOld == null, expectedOld == null);
            if (expectedOld != null) {
              expect(describe(actualOld!), describe(expectedOld));
            }
          } else {
            final expectedFrame = expectedList.get(key);
            final actualFrame = actual.get(key);
            expect(actualFrame == null, expectedFrame == null);
            if (expectedFrame != null) {
              expect(describe(actualFrame!), describe(expectedFrame));
            }
          }
          if (op % 997 == 0) compareAll();
        }
        compareAll();
      }

      for (final seed in [1, 2, 3, 4, 5]) {
        test('random reads and writes, seed $seed', () {
          runDifferential(seed, operations: 20000, keySpace: 3000);
        });
      }

      test('a small key space, mostly overwrites and deletes', () {
        runDifferential(11, operations: 20000, keySpace: 40);
      });

      test('a reversed comparator', () {
        runDifferential(
          12,
          operations: 10000,
          keySpace: 2000,
          comparator: (a, b) => defaultKeyComparator(b, a),
        );
      });
    });

    test('loads a large box in file order quickly', () {
      // A box opens by inserting every frame in file order; the index must not
      // shift its arrays once per key.
      const inputCount = 200000;
      final stopwatch = Stopwatch()..start();

      for (var i = 0; i < inputCount; i++) {
        final key = 'key${(i * 7919) % inputCount}';
        actualIndex.insert(key, lazyFrame(key, offset: i));
      }
      actualIndex.keys.first;

      expect(actualIndex.length, inputCount);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
