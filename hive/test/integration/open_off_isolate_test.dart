import 'package:hive_ce/hive.dart';
import 'package:test/test.dart';

import 'integration.dart';

class _Item with HiveObjectMixin {
  String name;

  _Item(this.name);
}

class _ItemAdapter extends TypeAdapter<_Item> {
  @override
  int get typeId => 0;

  @override
  _Item read(BinaryReader reader) => _Item(reader.readString());

  @override
  void write(BinaryWriter writer, _Item obj) => writer.writeString(obj.name);
}

/// A box past the size read on another isolate when it opens: its contents,
/// deletes and objects' ties to the box come back as they were written.
Future<void> _performTest(bool lazy) async {
  // Arrange
  final hive = await createHive(type: TestType.normal);
  await hive.registerAdapter<_Item>(_ItemAdapter());
  var (_, box) = await openBox(lazy, type: TestType.normal, hive: hive);
  final inputCount = 3000;
  final padding = 'x' * 40;
  await box.putAll({
    for (var i = 0; i < inputCount; i++) 'key$i': _Item('item $i $padding'),
  });
  await box.delete('key7');
  await box.put('key8', _Item('replaced'));

  // Act
  box = await hive.reopenBox(box);

  // Assert
  expect((await box.keys).length, inputCount - 1);
  expect(await box.get('key7'), null);
  final actualReplaced = await box.get('key8') as _Item;
  expect(actualReplaced.name, 'replaced');
  final actualLast = await box.get('key${inputCount - 1}') as _Item;
  expect(actualLast.name, 'item ${inputCount - 1} $padding');
  expect(actualLast.key, 'key${inputCount - 1}');

  // The reopened objects belong to the box: saving one writes it back.
  actualLast.name = 'saved';
  await actualLast.save();
  box = await hive.reopenBox(box);
  final actualSaved = await box.get('key${inputCount - 1}') as _Item;
  expect(actualSaved.name, 'saved');
  await box.close();
}

void main() {
  group(
    'opening a large box off the isolate',
    () {
      test('normal box', () => _performTest(false));
      test('lazy box', () => _performTest(true));
    },
    timeout: longTimeout,
  );
}
