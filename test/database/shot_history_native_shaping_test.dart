import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/native_shaping.dart';
import 'package:reaprime/src/models/data/shot_record.dart' as domain;
import 'package:reaprime/src/models/data/workflow.dart' as domain_workflow;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/storage/drift_bean_storage.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';
import 'package:reaprime/src/services/webserver/shots_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

final _report = NativeShapingReport.fromBytes([
  1, 0, 3, 0, //
  0x01, 0x05, 0x19, 0x19, 0x32, 0x0A, 0xC8, //
  0x1E, 0x78, 0x3C, 0x3C, 0x5A, 0x32, 0x78, //
  0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0, 0, 0, 0, 0, 0, 0,
]);

final _otherReport = NativeShapingReport.fromBytes([
  0, 0, 9, 0, //
  0x01, 0x01, 0x0A, 0x0A, 0x32, 0x0A, 0xC8, //
  0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0,
]);

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

  domain.ShotRecord shot(String id, {NativeShapingReport? report}) {
    final workflow = WorkflowController().currentWorkflow;
    return domain.ShotRecord(
      id: id,
      timestamp: DateTime.utc(2026, 11, 23, 8),
      measurements: const [],
      workflow: workflow.copyWith(
        id: workflow.id,
        machine: domain_workflow.WorkflowMachine(
          provenanceStatus:
              domain_workflow.WorkflowMachineProvenanceStatus.captured,
          model: '128',
          nativeShaping: report,
        ),
      ),
    );
  }

  Future<void> storeBoth() async {
    await storage.storeShot(shot('reported', report: _report));
    await storage.storeShot(shot('unreported'));
  }

  Future<Map<String, dynamic>> put(String id, Object body) async {
    final response = await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/shots/$id'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    final text = await response.readAsString();
    expect(response.statusCode, 200, reason: text);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Object? responseReport(Map<String, dynamic> body) =>
      ((body['workflow'] as Map)['machine'] as Map?)?['nativeShaping'];

  Future<NativeShapingReport?> storedReport(String id) async =>
      (await storage.getShot(id))!.workflow.machine?.nativeShaping;

  Map<String, dynamic> machineWith(Object? nativeShaping) => {
    'workflow': {
      'machine': {'nativeShaping': nativeShaping},
    },
  };

  test('a PUT ignores a nativeShaping value in the request', () async {
    await storeBoth();

    final body = await put('reported', machineWith(_otherReport.toJson()));

    expect(responseReport(body), _report.toJson());
    expect(await storedReport('reported'), _report);
  });

  test('a PUT without nativeShaping keeps the stored report', () async {
    await storeBoth();

    for (final patch in <Map<String, dynamic>>[
      {
        'annotations': {'espressoNotes': 'kept'},
      },
      {
        'workflow': {
          'machine': {'model': '128'},
        },
      },
      machineWith(null),
    ]) {
      final body = await put('reported', patch);

      expect(responseReport(body), _report.toJson(), reason: '$patch');
      expect(await storedReport('reported'), _report, reason: '$patch');
    }
  });

  test('a PUT cannot add a report to a shot that has none', () async {
    await storeBoth();

    final body = await put('unreported', machineWith(_report.toJson()));

    expect(responseReport(body), isNull);
    expect(await storedReport('unreported'), isNull);
  });

  test('a PUT ignores a partial nativeShaping object as a whole', () async {
    await storeBoth();

    for (final id in ['reported', 'unreported']) {
      final body = await put(
        id,
        machineWith({
          'latchCount': 99,
          'block': {'flow_tau': 4.0},
        }),
      );

      final expected = id == 'reported' ? _report : null;
      expect(responseReport(body), expected?.toJson(), reason: id);
      expect(await storedReport(id), expected, reason: id);
    }
  });
}
