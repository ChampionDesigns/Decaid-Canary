import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/machine.dart';

/// Locks the additive-compat contract of the nullable puck-estimator and
/// R1-collapse detector fields on [MachineSnapshot]: like weight/weightFlow/
/// milkTemperature they are additive, but they decode to `null` (not `0.0`)
/// when absent and are OMITTED from `toJson` when null — with the one twist
/// that `detEventCount` 0 is a REAL value and IS emitted.
void main() {
  MachineSnapshot snapshot() => MachineSnapshot(
    timestamp: DateTime.utc(2026, 7, 11, 12, 0, 0),
    state: MachineStateSnapshot(
      state: MachineState.espresso,
      substate: MachineSubstate.pouring,
    ),
    flow: 2.5,
    pressure: 9.0,
    targetFlow: 2.0,
    targetPressure: 6.0,
    mixTemperature: 92.5,
    groupTemperature: 88.0,
    targetMixTemperature: 93.0,
    targetGroupTemperature: 90.0,
    profileFrame: 7,
    steamTemperature: 135,
    weight: 36.5,
    weightFlow: 1.8,
    milkTemperature: 61.98,
  );

  group('MachineSnapshot json (fused-estimator fields)', () {
    MachineSnapshot withFused() => snapshot().copyWith(
          fusedR1: 1.77,
          fusedR2: 0.85,
          fusedC: 1.48,
          fusedConf: 0.8,
          vAbs: 21.5,
          estLag: 0.6,
          estFlags: 0x89,
        );

    const fusedKeys = [
      'fusedR1',
      'fusedR2',
      'fusedC',
      'fusedConf',
      'vAbs',
      'estLag',
      'estFlags',
    ];

    test('default snapshot leaves all fused fields null and omits the keys', () {
      final base = snapshot();
      expect(base.fusedR1, isNull);
      expect(base.fusedConf, isNull);
      expect(base.estFlags, isNull);
      final json = base.toJson();
      for (final k in fusedKeys) {
        expect(json.containsKey(k), isFalse, reason: '$k omitted when null');
      }
    });

    test('fromJson decodes absent fused keys to null (no fabricated 0)', () {
      final json = withFused().toJson()
        ..remove('fusedR1')
        ..remove('estFlags');
      final decoded = MachineSnapshot.fromJson(json);
      expect(decoded.fusedR1, isNull);
      expect(decoded.estFlags, isNull);
      // A key that is still present round-trips.
      expect(decoded.fusedR2, closeTo(0.85, 1e-9));
    });

    test('toJson -> fromJson round-trips every fused field', () {
      final decoded = MachineSnapshot.fromJson(withFused().toJson());
      expect(decoded.fusedR1, closeTo(1.77, 1e-9));
      expect(decoded.fusedR2, closeTo(0.85, 1e-9));
      expect(decoded.fusedC, closeTo(1.48, 1e-9));
      expect(decoded.fusedConf, closeTo(0.8, 1e-9));
      expect(decoded.vAbs, closeTo(21.5, 1e-9));
      expect(decoded.estLag, closeTo(0.6, 1e-9));
      expect(decoded.estFlags, 0x89);
    });

    test('fromJson tolerates integer-typed doubles and vice versa', () {
      final json = withFused().toJson()
        ..['fusedR1'] = 2 // int where a double is expected
        ..['estFlags'] = 5;
      final decoded = MachineSnapshot.fromJson(json);
      expect(decoded.fusedR1, 2.0);
      expect(decoded.estFlags, 5);
    });

    test('copyWith carries and overrides the fused fields', () {
      final base = withFused();
      expect(base.copyWith().fusedR1, closeTo(1.77, 1e-9));
      expect(base.copyWith(fusedR2: 0.9).fusedR2, closeTo(0.9, 1e-9));
      expect(base.copyWith(estFlags: 0x02).estFlags, 0x02);
    });
  });

  // The R1-collapse detector fields follow the same additive-compat /
  // omit-when-null rule as the fused fields. The one twist: detEventCount 0 is
  // a REAL value and IS emitted (0 != null), distinguishing "detector ran, no
  // collapse" from "no detector tail".
  group('MachineSnapshot json (R1-collapse detector fields)', () {
    MachineSnapshot withDet() => snapshot().copyWith(
          detEventCount: 2,
          detLastEventT: 30.0,
          detLastEventMag: 0.45,
          detLastEventConc: 0.85,
        );

    const detKeys = [
      'detEventCount',
      'detLastEventT',
      'detLastEventMag',
      'detLastEventConc',
    ];

    test('default snapshot leaves all detector fields null and omits keys', () {
      final base = snapshot();
      expect(base.detEventCount, isNull);
      expect(base.detLastEventT, isNull);
      expect(base.detLastEventMag, isNull);
      expect(base.detLastEventConc, isNull);
      final json = base.toJson();
      for (final k in detKeys) {
        expect(json.containsKey(k), isFalse, reason: '$k omitted when null');
      }
    });

    test('detEventCount 0 IS emitted (0 != null), other three still omit', () {
      // Detector ran but recorded no collapse yet: count present as 0, the
      // three event descriptors absent.
      final json = snapshot().copyWith(detEventCount: 0).toJson();
      expect(json.containsKey('detEventCount'), isTrue);
      expect(json['detEventCount'], 0);
      expect(json.containsKey('detLastEventT'), isFalse);
      expect(json.containsKey('detLastEventMag'), isFalse);
      expect(json.containsKey('detLastEventConc'), isFalse);
    });

    test('fromJson decodes absent detector keys to null (no fabricated 0)', () {
      final json = withDet().toJson()
        ..remove('detEventCount')
        ..remove('detLastEventConc');
      final decoded = MachineSnapshot.fromJson(json);
      expect(decoded.detEventCount, isNull);
      expect(decoded.detLastEventConc, isNull);
      // A key still present round-trips.
      expect(decoded.detLastEventT, closeTo(30.0, 1e-9));
    });

    test('toJson -> fromJson round-trips every detector field', () {
      final decoded = MachineSnapshot.fromJson(withDet().toJson());
      expect(decoded.detEventCount, 2);
      expect(decoded.detLastEventT, closeTo(30.0, 1e-9));
      expect(decoded.detLastEventMag, closeTo(0.45, 1e-9));
      expect(decoded.detLastEventConc, closeTo(0.85, 1e-9));
    });

    test('fromJson tolerates integer-typed doubles and vice versa', () {
      final json = withDet().toJson()
        ..['detLastEventMag'] = 1 // int where a double is expected
        ..['detEventCount'] = 3;
      final decoded = MachineSnapshot.fromJson(json);
      expect(decoded.detLastEventMag, 1.0);
      expect(decoded.detEventCount, 3);
    });

    test('copyWith carries and overrides the detector fields', () {
      final base = withDet();
      expect(base.copyWith().detEventCount, 2);
      expect(base.copyWith(detEventCount: 5).detEventCount, 5);
      expect(
        base.copyWith(detLastEventMag: 0.9).detLastEventMag,
        closeTo(0.9, 1e-9),
      );
    });
  });
}
