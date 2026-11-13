import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.utils.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:yaml/yaml.dart';

const _newSubstates = <int, String>{
  21: 'pumpZeroing',
  218: 'errorPumpZero',
  219: 'errorPumpNeedsCalibration',
  220: 'errorFrontSwitchOff',
  221: 'errorPumpFault',
  222: 'errorPumpSilent',
};

MachineSnapshot _snapshotWith(MachineState state, MachineSubstate substate) {
  return MachineSnapshot(
    timestamp: DateTime.utc(2026, 11, 13),
    state: MachineStateSnapshot(state: state, substate: substate),
    flow: 0,
    pressure: 0,
    targetFlow: 0,
    targetPressure: 0,
    mixTemperature: 0,
    groupTemperature: 0,
    targetMixTemperature: 0,
    targetGroupTemperature: 0,
    profileFrame: 0,
    steamTemperature: 0,
  );
}

List<String> _substates(String specPath) {
  final spec = loadYaml(File(specPath).readAsStringSync()) as YamlMap;
  final schemas = (spec['components'] as YamlMap)['schemas'] as YamlMap;
  final values = (schemas['MachineSubstate'] as YamlMap)['enum'] as YamlList;
  return values.map((value) => value.toString()).toList();
}

void main() {
  group('Bengle substates', () {
    for (final entry in _newSubstates.entries) {
      final name = entry.value;

      test('fromHexValue(${entry.key}) decodes to $name', () {
        final decoded = De1SubState.fromHexValue(entry.key);
        expect(decoded?.name, name);
        expect(decoded?.hexValue, entry.key);
      });

      test('$name maps to its own MachineSubstate', () {
        final decoded = De1SubState.fromHexValue(entry.key)!;
        expect(mapDe1SubToMachineSubstate(decoded).name, name);
      });
    }

    test('each new substate has a description', () {
      for (final hex in _newSubstates.keys) {
        expect(De1SubState.fromHexValue(hex)!.description, isNotEmpty);
      }
    });

    test('217 keeps its name and does not name the front button', () {
      final decoded = De1SubState.fromHexValue(217)!;
      expect(decoded, De1SubState.errorNoAC);
      expect(decoded.description, 'No AC power.');
      expect(mapDe1SubToMachineSubstate(decoded), MachineSubstate.errorNoAC);
    });

    test('values with no definition still decode to noState', () {
      for (final hex in [22, 199, 223, 255]) {
        expect(De1SubState.fromHexValue(hex), De1SubState.noState);
      }
    });

    test('state Busy with substate 21 gives busy and pumpZeroing', () {
      final state = De1StateEnum.fromHexValue(0x03);
      final substate = De1SubState.fromHexValue(21)!;
      expect(mapDe1ToMachineState(state), MachineState.busy);
      expect(mapDe1SubToMachineSubstate(substate).name, 'pumpZeroing');
    });
  });

  group('Bengle substate snapshot contract', () {
    test('round-trips each new substate name', () {
      for (final name in _newSubstates.values) {
        final substate = MachineSubstate.values.byName(name);
        final json = _snapshotWith(MachineState.busy, substate).toJson();
        expect((json['state'] as Map)['substate'], name);
        final restored = MachineSnapshot.fromJson(json);
        expect(restored.state.substate, substate);
      }
    });
  });

  group('MachineSubstate spec contract', () {
    final dartNames = MachineSubstate.values.map((e) => e.name).toList();

    test('rest_v1.yml MachineSubstate equals the Dart enum', () {
      expect(_substates('assets/api/rest_v1.yml'), dartNames);
    });

    test('websocket_v1.yml MachineSubstate equals the Dart enum', () {
      expect(_substates('assets/api/websocket_v1.yml'), dartNames);
    });
  });
}
