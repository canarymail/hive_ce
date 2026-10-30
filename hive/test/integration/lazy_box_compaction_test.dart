@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';

import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/hive_impl.dart';
import 'package:test/test.dart';

import '../tests/common.dart';

/// A lazy box keeps only where each value sits in its file, and compaction
/// moves values around in that file. These run a lazy box through real
/// compactions and check every value still reads back.
void main() {
  group('lazy box with compaction', () {
    late HiveImpl hive;
    late Directory dir;

    setUp(() async {
      dir = await getTempDir();
      hive = HiveImpl()..init(dir.path);
    });

    tearDown(() async {
      await hive.close();
    });

    Future<LazyBox<String>> open(String name) => hive.openLazyBox<String>(
          name,
          compactionStrategy: (entries, deleted) => deleted > 50,
        );

    Future<void> expectContents(
      LazyBox<String> box,
      Map<Object, String> expected,
    ) async {
      expect(box.length, expected.length);
      final expectedKeys = expected.keys.toList()
        ..sort((a, b) {
          if (a is int && b is String) return -1;
          if (a is String && b is int) return 1;
          return Comparable.compare(a as Comparable, b as Comparable);
        });
      expect(box.keys.toList(), expectedKeys);
      for (final entry in expected.entries) {
        expect(await box.get(entry.key), entry.value, reason: '${entry.key}');
      }
    }

    test('values read back after compactions, before and after reopening',
        () async {
      final random = Random(7);
      final name = generateBoxName();
      var box = await open(name);
      final expected = <Object, String>{};

      String valueFor(Object key, int version) =>
          '$key v$version ${'x' * random.nextInt(300)}';

      // Different value sizes move every frame when the box compacts.
      for (var i = 0; i < 3000; i++) {
        final key = i.isEven ? i as Object : 'key$i';
        expected[key] = valueFor(key, 0);
        await box.put(key, expected[key]!);
      }
      for (var round = 1; round <= 4; round++) {
        final batch = <Object, String>{};
        for (var i = 0; i < 400; i++) {
          final key = expected.keys.elementAt(random.nextInt(expected.length));
          batch[key] = valueFor(key, round);
        }
        await box.putAll(batch);
        expected.addAll(batch);
        final toDelete = {
          for (var j = 0; j < 60; j++)
            expected.keys.elementAt(random.nextInt(expected.length)),
        };
        await box.deleteAll(toDelete);
        toDelete.forEach(expected.remove);

        // Compacted on its own above; read through the moved offsets.
        await expectContents(box, expected);
      }

      final sizeBefore = await File(box.path!).length();
      await box.compact();
      final sizeAfter = await File(box.path!).length();
      expect(sizeAfter, lessThanOrEqualTo(sizeBefore));
      await expectContents(box, expected);

      await box.close();
      box = await open(name);
      await expectContents(box, expected);
    });

    test('writes racing a compaction land in the right place', () async {
      final name = generateBoxName();
      var box = await open(name);
      final expected = <Object, String>{};
      for (var i = 0; i < 500; i++) {
        expected['k$i'] = 'first $i';
      }
      await box.putAll(expected);

      // Overwrites queue a compaction; more writes queue behind it.
      final futures = <Future>[];
      for (var i = 0; i < 500; i++) {
        expected['k$i'] = 'second $i ${'y' * (i % 50)}';
        futures.add(box.put('k$i', expected['k$i']!));
        if (i % 7 == 0) {
          expected.remove('k${i ~/ 2}');
          futures.add(box.delete('k${i ~/ 2}'));
        }
      }
      futures.add(box.compact());
      await Future.wait(futures);

      await expectContents(box, expected);
      await box.close();
      box = await open(name);
      await expectContents(box, expected);
    });

    test('a read queued behind a compaction reads the moved value', () async {
      final name = generateBoxName();
      final box = await hive.openLazyBox<String>(
        name,
        compactionStrategy: (entries, deleted) => false,
      );
      for (var i = 0; i < 100; i++) {
        await box.put('k$i', 'v${i.toString().padLeft(3, '0')}');
      }
      for (var i = 0; i < 50; i++) {
        await box.delete('k$i');
      }

      final compaction = box.compact();
      final actualReads = [for (var i = 50; i < 100; i++) box.get('k$i')];
      await compaction;

      expect(await Future.wait(actualReads), [
        for (var i = 50; i < 100; i++) 'v${i.toString().padLeft(3, '0')}',
      ]);
    });

    test('.clear() then new writes read back', () async {
      final name = generateBoxName();
      var box = await open(name);
      await box.putAll({for (var i = 0; i < 300; i++) 'old$i': 'old'});

      await box.clear();
      await box.putAll({for (var i = 0; i < 300; i++) i: 'new $i'});

      final expected = {for (var i = 0; i < 300; i++) i: 'new $i'};
      await expectContents(box, expected);
      await box.close();
      box = await open(name);
      await expectContents(box, expected);
    });
  });
}
