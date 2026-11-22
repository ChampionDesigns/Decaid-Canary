import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart' as domain;
import 'package:reaprime/src/models/data/workflow.dart' as domain_workflow;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/storage/drift_bean_storage.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/shot_export_section.dart';
import 'package:reaprime/src/services/webserver/shots_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../data_export/streaming_test_helpers.dart';

void main() {
  late AppDatabase db;
  late DriftStorageService storage;
  late PersistenceController persistence;
  late Handler handler;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    storage = DriftStorageService(db);
    persistence = PersistenceController(storageService: storage);
    final app = Router().plus;
    ShotsHandler(
      controller: persistence,
      beanStorage: DriftBeanStorageService(db),
    ).addRoutes(app);
    handler = app.call;
  });

  tearDown(() async {
    persistence.dispose();
    await db.close();
  });

  domain.ShotRecord shot(String id, {required bool emulated, int minute = 0}) {
    final workflow = WorkflowController().currentWorkflow;
    return domain.ShotRecord(
      id: id,
      timestamp: DateTime.utc(2026, 11, 18, 8, minute),
      measurements: const [],
      workflow: workflow.copyWith(
        id: workflow.id,
        machine: domain_workflow.WorkflowMachine(
          provenanceStatus:
              domain_workflow.WorkflowMachineProvenanceStatus.captured,
          de1Emulation: emulated,
        ),
      ),
    );
  }

  Future<String> storeBoth() async {
    await storage.storeShot(shot('emulated', emulated: true, minute: 1));
    await storage.storeShot(shot('native', emulated: false));
    return WorkflowController().currentWorkflow.profile.title;
  }

  Future<dynamic> getJson(String path) async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost$path')),
    );
    expect(response.statusCode, 200);
    return jsonDecode(await response.readAsString());
  }

  test('the stored shot keeps the flag and the plain title', () async {
    final title = await storeBoth();

    final emulated = await storage.getShot('emulated');
    final native = await storage.getShot('native');

    expect(emulated!.de1Emulation, isTrue);
    expect(emulated.workflow.profile.title, title);
    expect(native!.de1Emulation, isFalse);
    final rows = await db.select(db.shotRecords).get();
    expect(rows.map((r) => r.profileTitle), everyElement(title));
  });

  test('a filter by profile title finds both kinds of shot', () async {
    final title = await storeBoth();

    final page = await storage.getShotsPaginated(profileTitle: title);
    expect(page.map((s) => s.id), ['emulated', 'native']);
    expect(await storage.countShots(profileTitle: title), 2);

    final prefixed = await storage.getShotsPaginated(
      profileTitle: 'B-DE1 · $title',
    );
    expect(prefixed, isEmpty);

    final body = await getJson(
      '/api/v1/shots?profileTitle=${Uri.encodeQueryComponent(title)}',
    );
    expect((body['items'] as List).map((s) => s['id']), ['emulated', 'native']);
    expect(body['total'], 2);
  });

  test('REST shot JSON carries the key only for an emulated shot', () async {
    await storeBoth();

    final full = await getJson('/api/v1/shots/emulated');
    expect(full['de1Emulation'], isTrue);
    final native = await getJson('/api/v1/shots/native');
    expect((native as Map).containsKey('de1Emulation'), isFalse);

    final list = await getJson('/api/v1/shots');
    final byId = {
      for (final item in list['items'] as List) item['id']: item as Map,
    };
    expect(byId['emulated']!['de1Emulation'], isTrue);
    expect(byId['native']!.containsKey('de1Emulation'), isFalse);

    final latest = await getJson('/api/v1/shots/latest');
    expect(latest['id'], 'emulated');
    expect(latest['de1Emulation'], isTrue);
  });

  test('an annotation update keeps the flag', () async {
    await storeBoth();

    final response = await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/shots/emulated'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'annotations': {'espressoNotes': 'emulated shot'},
        }),
      ),
    );

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString());
    expect(body['de1Emulation'], isTrue);
    expect((await storage.getShot('emulated'))!.de1Emulation, isTrue);
  });

  Future<Map<String, dynamic>> put(String id, Object body) async {
    final response = await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/shots/$id'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    expect(response.statusCode, 200);
    return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  }

  test('a PUT cannot mark a native shot as emulated', () async {
    await storeBoth();
    for (final body in [
      {'de1Emulation': true},
      {
        'workflow': {
          'machine': {'de1Emulation': true},
        },
      },
    ]) {
      final updated = await put('native', body);
      expect(updated.containsKey('de1Emulation'), isFalse, reason: '$body');
      expect((await storage.getShot('native'))!.de1Emulation, isFalse);
    }
  });

  test('a PUT cannot clear the flag of an emulated shot', () async {
    await storeBoth();
    for (final body in [
      {'de1Emulation': false},
      {
        'workflow': {
          'machine': {'de1Emulation': false},
        },
      },
      {
        'workflow': {'machine': null},
      },
    ]) {
      final updated = await put('emulated', body);
      expect(updated['de1Emulation'], isTrue, reason: '$body');
      expect((await storage.getShot('emulated'))!.de1Emulation, isTrue);
    }
  });

  test('data export and import keep the flag', () async {
    await storeBoth();
    final exporting = ShotExportSection(
      controller: persistence,
      pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
          afterTimestamp == null
          ? [
              (await storage.getShot('emulated'))!,
              (await storage.getShot('native'))!,
            ]
          : [],
    );
    final sink = CapturingJsonSink();
    await exporting.exportJson(sink);

    final exported = {
      for (final item in jsonDecode(sink.json) as List) item['id']: item as Map,
    };
    expect(exported['emulated']!['de1Emulation'], isTrue);
    expect(exported['native']!.containsKey('de1Emulation'), isFalse);

    final otherDb = AppDatabase(NativeDatabase.memory());
    addTearDown(otherDb.close);
    final otherStorage = DriftStorageService(otherDb);
    final otherPersistence = PersistenceController(
      storageService: otherStorage,
    );
    addTearDown(otherPersistence.dispose);
    final importing = ShotExportSection(
      controller: otherPersistence,
      pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async => [],
    );
    final result = await importSectionJson(
      importing,
      sink.json,
      ConflictStrategy.overwrite,
    );

    expect(result.imported, 2);
    expect((await otherStorage.getShot('emulated'))!.de1Emulation, isTrue);
    expect((await otherStorage.getShot('native'))!.de1Emulation, isFalse);
  });
}
