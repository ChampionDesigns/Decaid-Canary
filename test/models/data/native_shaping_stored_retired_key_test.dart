import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/native_shaping.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/workflow.dart' as domain;
import 'package:reaprime/src/services/database/database.dart' as db;
import 'package:reaprime/src/services/database/mappers/profile_mapper.dart';
import 'package:reaprime/src/services/database/mappers/workflow_mapper.dart';

Map<String, dynamic> _bundledJson() =>
    jsonDecode(File('assets/defaultProfiles/7g_basket.json').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _retiredBlock() => {
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

Map<String, dynamic> _profileWith(Map<String, dynamic> block) =>
    _bundledJson()..['native_shaping'] = block;

Map<String, dynamic> _workflowWith(Map<String, dynamic> block) => {
  'id': 'w1',
  'name': 'Stored',
  'description': '',
  'profile': _profileWith(block),
};

List<LogRecord> _captureProfileLog() {
  final records = <LogRecord>[];
  final sub = Logger.root.onRecord
      .where((r) => r.loggerName == 'Profile')
      .listen(records.add);
  addTearDown(sub.cancel);
  return records;
}

void main() {
  group('a stored block with ramp_factor', () {
    test('Profile.fromStoredJson loads without the block and logs one '
        'line', () {
      final log = _captureProfileLog();

      final profile = Profile.fromStoredJson(_profileWith(_retiredBlock()));

      expect(profile.nativeShaping, isNull);
      expect(profile.steps, isNotEmpty);
      expect(log, hasLength(1));
      expect(log.single.level, Level.WARNING);
      expect(log.single.message, contains('ramp_factor'));
    });

    test('Profile.fromJson still refuses it', () {
      expect(
        () => Profile.fromJson(_profileWith(_retiredBlock())),
        throwsArgumentError,
      );
    });

    test('a stored version 2 block without ramp_factor keeps the block', () {
      final log = _captureProfileLog();
      final block = NativeShaping.fromJson({'flow_ramp_tau': 0.5}).toJson();

      final profile = Profile.fromStoredJson(_profileWith(block));

      expect(profile.nativeShaping, NativeShaping.fromJson(block));
      expect(log, isEmpty);
    });

    test('ProfileMapper.fromRow loads the stored row without the block', () {
      final log = _captureProfileLog();
      final now = DateTime(2026, 11, 24);
      final row = db.ProfileRecord(
        id: 'profile:1',
        metadataHash: 'm',
        compoundHash: 'c',
        visibility: 'visible',
        isDefault: false,
        createdAt: now,
        updatedAt: now,
        profileJson: _profileWith(_retiredBlock()),
      );

      final record = ProfileMapper.fromRow(row);

      expect(record.profile.nativeShaping, isNull);
      expect(log, hasLength(1));
    });

    test('WorkflowMapper.fromRow loads the stored workflow without the '
        'block', () {
      final log = _captureProfileLog();
      final row = db.Workflow(
        id: 'current',
        workflowJson: _workflowWith(_retiredBlock()),
        updatedAt: DateTime(2026, 11, 24),
      );

      final workflow = WorkflowMapper.fromRow(row);

      expect(workflow.profile.nativeShaping, isNull);
      expect(log, hasLength(1));
    });

    test('Workflow.fromRecordedJson loads without the block', () {
      final workflow = domain.Workflow.fromRecordedJson(
        _workflowWith(_retiredBlock()),
      );

      expect(workflow.profile.nativeShaping, isNull);
    });

    test('Workflow.fromJson still refuses it', () {
      expect(
        () => domain.Workflow.fromJson(_workflowWith(_retiredBlock())),
        throwsArgumentError,
      );
    });
  });
}
