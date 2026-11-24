import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart' as domain;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/storage/drift_profile_storage.dart';

const _storedId = 'profile:stored-with-retired-block';

const _retiredBlock = <String, dynamic>{
  'version': 1,
  'pump_curve': [
    {'pressure': 3.0, 'flow': 12.0},
  ],
  'flow_tau': 0.5,
  'flow_mode': 'both',
  'pressure_tau': 0.5,
  'pressure_mode': 'both',
  'ramp_factor': 1.0,
};

Map<String, dynamic> _profileJson() =>
    jsonDecode(File('assets/defaultProfiles/7g_basket.json').readAsStringSync())
          as Map<String, dynamic>
      ..['title'] = 'Old shaped';

void main() {
  late AppDatabase database;
  late DriftProfileStorageService storage;
  late ProfileController controller;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    storage = DriftProfileStorageService(database);
    controller = ProfileController(storage: storage);
    final now = DateTime.utc(2026, 11, 1);
    await database
        .into(database.profileRecords)
        .insert(
          ProfileRecordsCompanion.insert(
            id: _storedId,
            metadataHash: 'stored-metadata-hash',
            compoundHash: 'stored-compound-hash',
            visibility: const Value('visible'),
            isDefault: const Value(false),
            createdAt: now,
            updatedAt: now,
            profileJson: {..._profileJson(), 'native_shaping': _retiredBlock},
          ),
        );
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  Future<List<ProfileRecord>> rows() =>
      database.select(database.profileRecords).get();

  Future<ProfileRecord> storedRow() => (database.select(
    database.profileRecords,
  )..where((p) => p.id.equals(_storedId))).getSingle();

  Future<domain.ProfileRecord> storeUnshapedTwin() async {
    final twin = domain.ProfileRecord.create(
      profile: Profile.fromJson(_profileJson()),
    );
    await storage.store(twin);
    return twin;
  }

  for (final withTwin in [false, true]) {
    group(withTwin ? 'with an unshaped twin' : 'without an unshaped twin', () {
      domain.ProfileRecord? twin;
      setUp(() async {
        twin = withTwin ? await storeUnshapedTwin() : null;
      });

      test('a visibility edit updates the stored row by its id and keeps '
          'its stored block', () async {
        final result = await controller.setVisibility(
          _storedId,
          domain.Visibility.hidden,
        );

        expect(result.id, _storedId);
        final row = await storedRow();
        expect(row.visibility, 'hidden');
        expect(row.profileJson['native_shaping'], _retiredBlock);
        expect(row.metadataHash, 'stored-metadata-hash');
        expect(await rows(), hasLength(withTwin ? 2 : 1));
        if (twin != null) expect(await storage.get(twin!.id), twin);
      });

      test('a metadata edit updates the stored row by its id and keeps its '
          'stored block', () async {
        final result = await controller.update(
          _storedId,
          metadata: {'note': 'edited'},
        );

        expect(result.id, _storedId);
        final row = await storedRow();
        expect(row.metadata, {'note': 'edited'});
        expect(row.profileJson['native_shaping'], _retiredBlock);
        expect(await rows(), hasLength(withTwin ? 2 : 1));
        if (twin != null) expect(await storage.get(twin!.id), twin);
      });

      test('a soft delete updates the stored row by its id and keeps its '
          'stored block', () async {
        await controller.delete(_storedId);

        final row = await storedRow();
        expect(row.visibility, 'deleted');
        expect(row.profileJson['native_shaping'], _retiredBlock);
        if (twin != null) expect(await storage.get(twin!.id), twin);
      });
    });
  }

  test('a content edit writes the new profile JSON', () async {
    final edited = Profile.fromJson(_profileJson()).copyWith(notes: 'new');

    final result = await controller.update(_storedId, profile: edited);

    final row = (await rows()).singleWhere((r) => r.id == result.id);
    expect(row.profileJson['notes'], 'new');
    expect(row.profileJson, isNot(contains('native_shaping')));
  });

  test('an update of a row that does not exist throws and writes '
      'nothing', () async {
    final stored = await storage.get(_storedId);
    final missing = stored!.copyWith(id: 'profile:missing');

    await expectLater(storage.update(missing), throwsArgumentError);
    expect(await rows(), hasLength(1));
  });
}
