import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/services/database/database.dart'
    hide ProfileRecord;
import 'package:reaprime/src/services/storage/drift_profile_storage.dart';

Profile _profile(double tankTemperature, {String title = 'Profile'}) {
  return Profile(
    version: '2',
    title: title,
    author: 'Test',
    notes: '',
    beverageType: BeverageType.espresso,
    steps: [
      ProfileStepPressure(
        name: 'pour',
        transition: TransitionType.fast,
        volume: 100,
        seconds: 30,
        temperature: 93,
        sensor: TemperatureSensor.coffee,
        pressure: 9,
      ),
    ],
    tankTemperature: tankTemperature,
    targetVolumeCountStart: 0,
  );
}

void main() {
  late AppDatabase database;
  late DriftProfileStorageService storage;
  late ProfileController controller;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    storage = DriftProfileStorageService(database);
    controller = ProfileController(storage: storage);
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  test('an update whose new hash matches an existing record returns that '
      'record and deletes no row', () async {
    final original = ProfileRecord.create(profile: _profile(93));
    final existing = ProfileRecord.create(
      profile: _profile(94, title: 'Existing'),
    );
    await storage.store(original);
    await storage.store(existing);

    final result = await controller.update(
      original.id,
      profile: _profile(94, title: 'Edited'),
    );

    expect(result, existing);
    expect(await storage.get(existing.id), existing);
    expect(await storage.get(original.id), original);
    expect(await storage.count(), 2);
  });

  test('an update that changes the parent hash moves both children to the '
      'new id', () async {
    final parent = ProfileRecord.create(profile: _profile(93));
    final childA = ProfileRecord.create(
      profile: _profile(91, title: 'Child A'),
      parentId: parent.id,
    );
    final childB = ProfileRecord.create(
      profile: _profile(92, title: 'Child B'),
      parentId: parent.id,
    );
    await storage.store(parent);
    await storage.store(childA);
    await storage.store(childB);
    await controller.setVisibility(parent.id, Visibility.hidden);

    final updated = await controller.update(
      parent.id,
      profile: _profile(95, title: 'Parent v2'),
    );

    expect(updated.id, isNot(parent.id));
    expect(await storage.get(parent.id), isNull);
    expect(await storage.getByParentId(parent.id), isEmpty);
    final children = await storage.getByParentId(updated.id);
    expect(
      children.map((child) => child.id),
      unorderedEquals([childA.id, childB.id]),
    );
    expect((await storage.get(updated.id))?.visibility, Visibility.hidden);
    expect(await storage.count(), 3);
  });
}
