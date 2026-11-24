import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart' as domain;
import 'package:reaprime/src/models/data/steam_record.dart' as domain;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';
import 'package:reaprime/src/services/webserver/shots_handler.dart';
import 'package:reaprime/src/services/webserver/steams_handler.dart';
import 'package:reaprime/src/services/storage/drift_bean_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';

const _retiredBlock = <String, dynamic>{
  'version': 1,
  'pump_curve': [
    {'pressure': 1.0, 'flow': 20.0},
    {'pressure': 3.0, 'flow': 12.0},
  ],
  'flow_tau': 0.5,
  'flow_mode': 'both',
  'pressure_tau': 0.5,
  'pressure_mode': 'both',
  'ramp_factor': 1.0,
};

const _retiredReport = <String, dynamic>{
  'source': 'profile',
  'sourceCode': 1,
  'refusal': 'none',
  'refusalCode': 0,
  'latchCount': 3,
  'settingsRounded': false,
  'settings': _retiredBlock,
};

Map<String, dynamic> _withRetiredBlocks(Map<String, dynamic> workflow) {
  final json = jsonDecode(jsonEncode(workflow)) as Map<String, dynamic>;
  (json['profile'] as Map<String, dynamic>)['native_shaping'] = _retiredBlock;
  json['machine'] = {'nativeShaping': _retiredReport};
  return json;
}

void main() {
  late AppDatabase db;
  late PersistenceController persistence;
  late Handler handler;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    persistence = PersistenceController(
      storageService: DriftStorageService(db),
    );
    final app = Router().plus;
    ShotsHandler(
      controller: persistence,
      beanStorage: DriftBeanStorageService(db),
    ).addRoutes(app);
    SteamsHandler(controller: persistence).addRoutes(app);
    handler = app.call;
  });

  tearDown(() async {
    persistence.dispose();
    await db.close();
  });

  Future<Response> put(String path, Map<String, dynamic> body) async => handler(
    Request(
      'PUT',
      Uri.parse('http://localhost$path'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    ),
  );

  void expectRetiredBlocksKept(Map<String, dynamic> workflow) {
    expect(
      (workflow['profile'] as Map)['native_shaping'],
      _retiredBlock,
      reason: 'profile block',
    );
    final report = (workflow['machine'] as Map)['nativeShaping'] as Map;
    for (final entry in _retiredReport.entries) {
      expect(report[entry.key], entry.value, reason: 'report ${entry.key}');
    }
  }

  group('a shot stored before block version 2', () {
    setUp(() async {
      await persistence.persistShot(
        domain.ShotRecord(
          id: 'old',
          timestamp: DateTime.utc(2026, 11, 1, 10),
          measurements: const [],
          workflow: WorkflowController().currentWorkflow,
        ),
      );
      final row = await (db.select(
        db.shotRecords,
      )..where((s) => s.id.equals('old'))).getSingle();
      await (db.update(db.shotRecords)..where((s) => s.id.equals('old'))).write(
        ShotRecordsCompanion(
          workflowJson: Value(_withRetiredBlocks(row.workflowJson)),
        ),
      );
    });

    test('keeps both retired blocks after a note edit through PUT', () async {
      final response = await put('/api/v1/shots/old', {
        'annotations': {'espressoNotes': 'edited'},
      });
      expect(response.statusCode, 200);

      final row = await (db.select(
        db.shotRecords,
      )..where((s) => s.id.equals('old'))).getSingle();
      expect(row.espressoNotes, 'edited');
      expectRetiredBlocksKept(row.workflowJson);
      final body = jsonDecode(await response.readAsString()) as Map;
      expectRetiredBlocksKept(body['workflow'] as Map<String, dynamic>);
    });

    test('reads with no decoded settings and no profile block', () async {
      final shot = await persistence.storageService.getShot('old');

      expect(shot!.workflow.profile.nativeShaping, isNull);
      expect(shot.workflow.machine!.nativeShaping!.settings, isNull);
    });
  });

  group('a steam record stored before block version 2', () {
    setUp(() async {
      await persistence.persistSteam(
        domain.SteamRecord(
          id: 'steam',
          timestamp: DateTime.utc(2026, 11, 1, 10),
          measurements: const [],
          workflow: WorkflowController().currentWorkflow,
        ),
      );
      final row = await (db.select(
        db.steamRecords,
      )..where((s) => s.id.equals('steam'))).getSingle();
      await (db.update(
        db.steamRecords,
      )..where((s) => s.id.equals('steam'))).write(
        SteamRecordsCompanion(
          workflowJson: Value(_withRetiredBlocks(row.workflowJson)),
        ),
      );
    });

    test('keeps both retired blocks after a note edit through PUT', () async {
      final response = await put('/api/v1/steams/steam', {
        'annotations': {'espressoNotes': 'edited'},
      });
      expect(response.statusCode, 200);

      final row = await (db.select(
        db.steamRecords,
      )..where((s) => s.id.equals('steam'))).getSingle();
      expectRetiredBlocksKept(row.workflowJson);
    });
  });
}
