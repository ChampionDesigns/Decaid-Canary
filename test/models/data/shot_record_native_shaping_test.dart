import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/native_shaping.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';

Profile _bundledProfile() => Profile.fromJson(
  jsonDecode(File('assets/defaultProfiles/7g_basket.json').readAsStringSync())
      as Map<String, dynamic>,
);

final _report = NativeShapingReport.fromBytes([
  1, 0, 3, 0, //
  0x01, 0x05, 0x19, 0x19, 0x32, 0x0A, 0xC8, //
  0x1E, 0x78, 0x3C, 0x3C, 0x5A, 0x32, 0x78, //
  0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0, 0, 0, 0, 0, 0, 0,
]);

ShotRecord _shot(WorkflowMachine? machine) => ShotRecord(
  id: 'shot-1',
  timestamp: DateTime.utc(2026, 11, 23, 8),
  createdAt: DateTime.utc(2026, 11, 23, 8),
  updatedAt: DateTime.utc(2026, 11, 23, 8),
  measurements: const [],
  workflow: Workflow(
    id: 'workflow-1',
    name: 'Workflow',
    profile: _bundledProfile(),
    steamSettings: SteamSettings.defaults(),
    hotWaterData: HotWaterData.defaults(),
    rinseData: RinseData.defaults(),
    machine: machine,
  ),
);

Map<String, dynamic> _roundTrip(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void main() {
  group('WorkflowMachine.nativeShaping', () {
    const plain = WorkflowMachine(
      provenanceStatus: WorkflowMachineProvenanceStatus.captured,
      model: '128',
    );

    test('is absent from JSON when there is no report', () {
      expect(plain.nativeShaping, isNull);
      expect(plain.toJson().containsKey('nativeShaping'), isFalse);
      expect(WorkflowMachine.fromJson(plain.toJson()), plain);
    });

    test('round-trips a report through JSON', () {
      final machine = plain.copyWith(nativeShaping: _report);
      final json = _roundTrip(machine.toJson());

      expect(json['nativeShaping'], _report.toJson());
      expect(WorkflowMachine.fromJson(json), machine);
      expect(machine, isNot(plain));
    });

    test('a report it cannot read loads as absent', () {
      final json = plain.toJson()..['nativeShaping'] = {'sourceCode': 'x'};

      expect(WorkflowMachine.fromJson(json), plain);
    });
  });

  group('ShotRecord with a native shaping report', () {
    test('keeps the report at workflow.machine.nativeShaping', () {
      final record = _shot(
        const WorkflowMachine(
          provenanceStatus: WorkflowMachineProvenanceStatus.captured,
        ).copyWith(nativeShaping: _report),
      );
      final json = _roundTrip(record.toJson());
      final machine =
          (json['workflow'] as Map<String, dynamic>)['machine']
              as Map<String, dynamic>;

      expect(machine['nativeShaping'], _report.toJson());
      expect(
        ShotRecord.fromJson(json).workflow.machine?.nativeShaping,
        _report,
      );
    });

    test('a record without the key parses as before', () {
      final record = _shot(
        const WorkflowMachine(
          provenanceStatus: WorkflowMachineProvenanceStatus.captured,
          de1Emulation: true,
        ),
      );
      final json = _roundTrip(record.toJson());
      final machine =
          (json['workflow'] as Map<String, dynamic>)['machine']
              as Map<String, dynamic>;

      expect(machine.containsKey('nativeShaping'), isFalse);
      final parsed = ShotRecord.fromJson(json);
      expect(parsed.workflow.machine?.nativeShaping, isNull);
      expect(parsed.workflow.machine, record.workflow.machine);
      expect(parsed.de1Emulation, isTrue);
    });
  });
}
