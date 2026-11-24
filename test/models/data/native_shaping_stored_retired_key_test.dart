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

  group('a recorded block with ramp_factor is kept as recorded', () {
    test('Profile.fromRecordedJson keeps the block raw, writes it back and '
        'logs nothing', () {
      final log = _captureProfileLog();

      final profile = Profile.fromRecordedJson(_profileWith(_retiredBlock()));

      expect(profile.nativeShaping, isNull);
      expect(profile.retiredNativeShapingJson, _retiredBlock());
      expect(profile.toJson()['native_shaping'], _retiredBlock());
      expect(log, isEmpty);
    });

    test('a kept block makes the profile differ from one without it', () {
      final kept = Profile.fromRecordedJson(_profileWith(_retiredBlock()));
      final without = Profile.fromRecordedJson(_bundledJson());

      expect(kept, isNot(without));
    });

    test('copyWith keeps the raw block until a new block replaces it or it '
        'is cleared', () {
      final kept = Profile.fromRecordedJson(_profileWith(_retiredBlock()));
      final block = NativeShaping.fromJson({'flow_ramp_tau': 0.5});

      expect(
        kept.copyWith(title: 'x').toJson()['native_shaping'],
        _retiredBlock(),
      );
      expect(
        kept.copyWith(nativeShaping: block).toJson()['native_shaping'],
        block.toJson(),
      );
      expect(
        kept.copyWith(clearNativeShaping: true).toJson(),
        isNot(contains('native_shaping')),
      );
    });

    test('Workflow.fromRecordedJson round-trips the block through JSON', () {
      final json = _workflowWith(_retiredBlock());

      final workflow = domain.Workflow.fromRecordedJson(json);
      final again = domain.Workflow.fromRecordedJson(
        jsonDecode(jsonEncode(workflow.toJson())) as Map<String, dynamic>,
      );

      expect(
        (again.toJson()['profile'] as Map)['native_shaping'],
        _retiredBlock(),
      );
    });

    test('a report with version 1 settings keeps them raw and gives no '
        'decoded settings', () {
      final json = {
        'sourceCode': 1,
        'refusalCode': 0,
        'latchCount': 3,
        'settingsRounded': false,
        'settings': _retiredBlock(),
      };

      final report = NativeShapingReport.fromJson(json);

      expect(report.settings, isNull);
      expect(report.retiredSettingsJson, _retiredBlock());
      expect(report.toJson()['settings'], _retiredBlock());
      expect(
        NativeShapingReport.fromJson(
          jsonDecode(jsonEncode(report.toJson())) as Map<String, dynamic>,
        ),
        report,
      );
    });

    test('an inactive report drops its settings, as fromBytes does', () {
      final report = NativeShapingReport.fromJson({
        'sourceCode': 3,
        'refusalCode': 0,
        'latchCount': 3,
        'settingsRounded': false,
        'settings': _retiredBlock(),
      });

      expect(report.retiredSettingsJson, isNull);
      expect(report.toJson(), isNot(contains('settings')));
    });
  });
}
