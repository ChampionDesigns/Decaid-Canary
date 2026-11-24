import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/storage/drift_profile_storage.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/profile_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/steam_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/workflow_export_section.dart';

import 'streaming_test_helpers.dart';

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

Map<String, dynamic> _baseProfileJson() =>
    (jsonDecode(
        File('assets/defaultProfiles/7g_basket.json').readAsStringSync(),
      ) as Map<String, dynamic>)
      ..['title'] = 'Old shaped'
      ..['native_shaping'] = _retiredBlock;

Map<String, dynamic> _baseProfileRecord({Map<String, dynamic>? metadata}) => {
  'id': 'profile:archived-with-retired-block',
  'profile': _baseProfileJson(),
  'metadataHash': 'archived-metadata-hash',
  'compoundHash': 'archived-compound-hash',
  'parentId': null,
  'visibility': 'visible',
  'isDefault': false,
  'createdAt': '2026-11-01T00:00:00.000Z',
  'updatedAt': '2026-11-01T00:00:00.000Z',
  'metadata': metadata,
};

Map<String, dynamic> _baseWorkflow() => {
  'id': 'wf-old',
  'name': 'Old workflow',
  'description': '',
  'profile': _baseProfileJson(),
};

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('profiles section, archive in the base format', () {
    late DriftProfileStorageService storage;
    late ProfileController controller;
    late ProfileExportSection section;

    setUp(() {
      storage = DriftProfileStorageService(db);
      controller = ProfileController(storage: storage);
      section = ProfileExportSection(controller: controller);
    });
    tearDown(() => controller.dispose());

    test('imports a profile whose block has ramp_factor, without the '
        'block', () async {
      final result = await importSectionJson(
        section,
        jsonEncode([_baseProfileRecord()]),
        ConflictStrategy.skip,
      );

      expect(result.errors, isEmpty);
      expect(result.imported, 1);
      final stored = await storage.get('profile:archived-with-retired-block');
      expect(stored!.profile.title, 'Old shaped');
      expect(stored.profile.nativeShaping, isNull);
    });

    test('overwrite of the same stored profile keeps its id and stored '
        'block and takes the metadata', () async {
      await db
          .into(db.profileRecords)
          .insert(
            ProfileRecordsCompanion.insert(
              id: 'profile:archived-with-retired-block',
              metadataHash: 'archived-metadata-hash',
              compoundHash: 'archived-compound-hash',
              createdAt: DateTime.utc(2026, 11),
              updatedAt: DateTime.utc(2026, 11),
              profileJson: _baseProfileJson(),
            ),
          );

      final result = await importSectionJson(
        section,
        jsonEncode([
          _baseProfileRecord(metadata: {'note': 'from archive'}),
        ]),
        ConflictStrategy.overwrite,
      );

      expect(result.errors, isEmpty);
      final rows = await db.select(db.profileRecords).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, 'profile:archived-with-retired-block');
      expect(rows.single.metadata, {'note': 'from archive'});
      expect(rows.single.profileJson['native_shaping'], _retiredBlock);
    });
  });

  test('workflow section imports a workflow whose profile block has '
      'ramp_factor, without the block', () async {
    final workflows = WorkflowController();
    final section = WorkflowExportSection(controller: workflows);

    final result = await importSectionJson(
      section,
      jsonEncode(_baseWorkflow()),
      ConflictStrategy.overwrite,
    );

    expect(result.errors, isEmpty);
    expect(result.imported, 1);
    expect(workflows.currentWorkflow.id, 'wf-old');
    expect(workflows.currentWorkflow.profile.nativeShaping, isNull);
    expect(
      workflows.currentWorkflow.toJson()['profile'],
      isNot(contains('native_shaping')),
    );
  });

  test('steam section imports a record whose profile block has ramp_factor '
      'and keeps the block as recorded', () async {
    final persistence = PersistenceController(
      storageService: DriftStorageService(db),
    );
    addTearDown(persistence.dispose);
    final section = SteamExportSection(
      controller: persistence,
      pageSteams: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
          const [],
    );

    final result = await importSectionJson(
      section,
      jsonEncode([
        {
          'id': 'steam-old',
          'timestamp': '2026-11-01T10:00:00.000Z',
          'measurements': const [],
          'workflow': _baseWorkflow(),
        },
      ]),
      ConflictStrategy.skip,
    );

    expect(result.errors, isEmpty);
    expect(result.imported, 1);
    final row = await db.select(db.steamRecords).getSingle();
    expect(
      (row.workflowJson['profile'] as Map)['native_shaping'],
      _retiredBlock,
    );
  });
}
