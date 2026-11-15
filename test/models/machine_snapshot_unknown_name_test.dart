import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/steam_snapshot.dart';
import 'package:reaprime/src/models/device/machine.dart';

MachineSnapshot _snapshot(MachineState state, MachineSubstate substate) {
  return MachineSnapshot(
    timestamp: DateTime.utc(2026, 11, 13, 12),
    state: MachineStateSnapshot(state: state, substate: substate),
    flow: 2.0,
    pressure: 9.0,
    targetFlow: 2.0,
    targetPressure: 9.0,
    mixTemperature: 93.0,
    groupTemperature: 92.0,
    targetMixTemperature: 93.0,
    targetGroupTemperature: 92.0,
    profileFrame: 3,
    steamTemperature: 150,
  );
}

Map<String, dynamic> _storedJson({String? state, String? substate}) {
  final json = jsonDecode(
    jsonEncode(
      _snapshot(MachineState.espresso, MachineSubstate.pouring).toJson(),
    ),
  ) as Map<String, dynamic>;
  final stateJson = json['state'] as Map<String, dynamic>;
  if (state != null) stateJson['state'] = state;
  if (substate != null) stateJson['substate'] = substate;
  return json;
}

void main() {
  group('MachineSnapshot.fromJson with a name the app does not know', () {
    test('an unknown state name reads as error and keeps the substate', () {
      final restored = MachineSnapshot.fromJson(
        _storedJson(state: 'futureState'),
      );

      expect(restored.state.state, MachineState.error);
      expect(restored.state.substate, MachineSubstate.pouring);
      expect(restored.flow, 2.0);
    });

    test('an unknown substate name reads as idle and keeps the state', () {
      final restored = MachineSnapshot.fromJson(
        _storedJson(substate: 'futureSubstate'),
      );

      expect(restored.state.state, MachineState.espresso);
      expect(restored.state.substate, MachineSubstate.idle);
      expect(restored.pressure, 9.0);
    });

    test('unknown state and substate names read as error and idle', () {
      final restored = MachineSnapshot.fromJson(
        _storedJson(state: 'futureState', substate: 'futureSubstate'),
      );

      expect(restored.state.state, MachineState.error);
      expect(restored.state.substate, MachineSubstate.idle);
    });

    test('a ShotSnapshot with an unknown substate name loads', () {
      final restored = ShotSnapshot.fromJson({
        'machine': _storedJson(substate: 'futureSubstate'),
      });

      expect(restored.machine.state.state, MachineState.espresso);
      expect(restored.machine.state.substate, MachineSubstate.idle);
    });

    test('a SteamSnapshot with an unknown substate name loads', () {
      final restored = SteamSnapshot.fromJson({
        'machine': _storedJson(substate: 'futureSubstate'),
      });

      expect(restored.machine.state.state, MachineState.espresso);
      expect(restored.machine.state.substate, MachineSubstate.idle);
    });
  });

  group('MachineSnapshot.fromJson with a known name', () {
    for (final state in MachineState.values) {
      test('state ${state.name} round-trips', () {
        final json = jsonDecode(
          jsonEncode(_snapshot(state, MachineSubstate.idle).toJson()),
        ) as Map<String, dynamic>;

        expect(MachineSnapshot.fromJson(json).state.state, state);
      });
    }

    for (final substate in MachineSubstate.values) {
      test('substate ${substate.name} round-trips', () {
        final json = jsonDecode(
          jsonEncode(_snapshot(MachineState.busy, substate).toJson()),
        ) as Map<String, dynamic>;

        expect(MachineSnapshot.fromJson(json).state.substate, substate);
      });
    }
  });
}
