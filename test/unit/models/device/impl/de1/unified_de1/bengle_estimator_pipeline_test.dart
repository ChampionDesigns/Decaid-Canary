import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/machine.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

/// Golden 0xA013 frame (weight 36.5 g, group pressure 9.00 bar) — full
/// breakdown in `bengle_shot_sample_test.dart`.
final Uint8List _golden0xA013 = Uint8List.fromList(const [
  0x03, 0xE8, 0x03, 0x84, 0x02, 0x58, 0x00, 0xFA, 0x00, 0xC8, 0x00, 0xB4, //
  0x24, 0x22, 0x22, 0x60, 0x24, 0x54, 0x23, 0x28, 0x04, 0x90, 0x07, 0x34, //
  0xBC, 0x00, 0x00, 0x00,
]);

/// Golden 0xA014 estimator frame (R1 1.77, R2 0.85, C 1.48, conf 0.8, lag 0.6,
/// V_abs 21.5, flags 0x89) — full breakdown in `bengle_est_sample_test.dart`.
const List<int> _golden0xA014 = [
  0x01, 0x89, 0x00, 0xB1, 0x03, 0x52, 0x05, 0xC8, //
  0xCC, 0x06, 0x66, 0x0F, 0x00, 0xD7, 0x01, 0x40,
];

/// Golden Rev-2 0xA014 frame: bytes 0–15 as [_golden0xA014] but Rev = 2, plus
/// the R1-collapse detector tail (DetEventCount 2, DetLastEventT 30.0 s,
/// DetLastEventMag 0.45, DetLastEventConc 0.85) — see `bengle_est_sample_test`.
const List<int> _golden0xA014V2 = [
  0x02, 0x89, 0x00, 0xB1, 0x03, 0x52, 0x05, 0xC8, //
  0xCC, 0x06, 0x66, 0x0F, 0x00, 0xD7, 0x01, 0x40, //
  0x02, 0x01, 0x2C, 0x5A, 0xAA,
];

/// The seven fused-estimator keys the snapshot exposes.
const _fusedKeys = [
  'fusedR1',
  'fusedR2',
  'fusedC',
  'fusedConf',
  'vAbs',
  'estLag',
  'estFlags',
];

/// The four R1-collapse detector keys the snapshot exposes (Rev-2 tail).
const _detKeys = [
  'detEventCount',
  'detLastEventT',
  'detLastEventMag',
  'detLastEventConc',
];

ByteData _est(List<int> b) => ByteData.sublistView(Uint8List.fromList(b));

void main() {
  group('Bengle 0xA014 estimator → snapshot fold', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    setUp(() async {
      transport = FakeBleTransport();
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
      transport.queueOnConnectResponses(v13Model: 128);
      bengle = Bengle(transport: transport);
      await bengle.onConnect();
      expect(bengle.isBengle, isTrue);
    });

    tearDown(() => transport.dispose());

    test(
      'before any [T]: fused keys are null and OMITTED from toJson',
      () async {
        final snapshots = <MachineSnapshot>[];
        final sub = bengle.currentSnapshot.listen(snapshots.add);
        await pumpEventQueue();

        transport.subscribers[Endpoint.bengleShotSample.uuid]!(_golden0xA013);
        await pumpEventQueue();

        final snap = snapshots.last;
        // The 0xA013 fields still populate (fold does not disturb them).
        expect(snap.weight, closeTo(36.5, 1e-9));
        // No estimator frame yet → every fused field null.
        expect(snap.fusedR1, isNull);
        expect(snap.fusedR2, isNull);
        expect(snap.fusedC, isNull);
        expect(snap.fusedConf, isNull);
        expect(snap.vAbs, isNull);
        expect(snap.estLag, isNull);
        expect(snap.estFlags, isNull);
        final json = snap.toJson();
        for (final k in _fusedKeys) {
          expect(json.containsKey(k), isFalse, reason: '$k must be omitted');
        }

        await sub.cancel();
      },
    );

    test(
      'a streamed estimator sample populates the fused keys (present in toJson)',
      () async {
        final snapshots = <MachineSnapshot>[];
        final sub = bengle.currentSnapshot.listen(snapshots.add);
        await pumpEventQueue();

        // Inject the estimator frame FIRST so withLatestFrom2 has it cached,
        // then a 0xA013 frame drives the combined emission.
        bengle.debugInjectEstimator(_est(_golden0xA014));
        await pumpEventQueue();
        transport.subscribers[Endpoint.bengleShotSample.uuid]!(_golden0xA013);
        await pumpEventQueue();

        final snap = snapshots.last;
        expect(snap.fusedR1, closeTo(1.77, 1e-9));
        expect(snap.fusedR2, closeTo(0.85, 1e-9));
        expect(snap.fusedC, closeTo(1.48, 1e-9));
        expect(snap.fusedConf, closeTo(0.8, 1e-9));
        expect(snap.vAbs, closeTo(21.5, 1e-9));
        expect(snap.estLag, closeTo(0.6, 1e-9));
        expect(snap.estFlags, 0x89);
        // The 0xA013 fields are untouched by the fold.
        expect(snap.weight, closeTo(36.5, 1e-9));
        expect(snap.pressure, closeTo(9.00, 1e-9));

        final json = snap.toJson();
        for (final k in _fusedKeys) {
          expect(json.containsKey(k), isTrue, reason: '$k must be present');
        }
        expect(json['fusedR1'], closeTo(1.77, 1e-9));
        expect(json['estFlags'], 0x89);

        await sub.cancel();
      },
    );

    test(
      'per-field sentinels decode to null and drop only those keys from toJson',
      () async {
        final snapshots = <MachineSnapshot>[];
        final sub = bengle.currentSnapshot.listen(snapshots.add);
        await pumpEventQueue();

        // Sentinel R1/R2/C/VAbs (0xFFFF) + Lag (0xFF); keep valid Rev/Flags/
        // ConfR so the frame decodes but those fields are "unobserved".
        final sentinel = List<int>.from(_golden0xA014);
        sentinel[2] = 0xFF;
        sentinel[3] = 0xFF; // R1
        sentinel[4] = 0xFF;
        sentinel[5] = 0xFF; // R2
        sentinel[6] = 0xFF;
        sentinel[7] = 0xFF; // C
        sentinel[9] = 0xFF; // Lag
        sentinel[12] = 0xFF;
        sentinel[13] = 0xFF; // VAbs

        bengle.debugInjectEstimator(_est(sentinel));
        await pumpEventQueue();
        transport.subscribers[Endpoint.bengleShotSample.uuid]!(_golden0xA013);
        await pumpEventQueue();

        final json = snapshots.last.toJson();
        // Sentinel-bearing fields → keys omitted.
        for (final k in ['fusedR1', 'fusedR2', 'fusedC', 'vAbs', 'estLag']) {
          expect(json.containsKey(k), isFalse, reason: '$k must be omitted');
        }
        // Non-sentinel fields still present (an estimator frame DID arrive).
        expect(json['fusedConf'], closeTo(0.8, 1e-9));
        expect(json['estFlags'], 0x89);

        await sub.cancel();
      },
    );
  });

  // The R1-collapse detector tail folds through the SAME withLatestFrom
  // pipeline as the fused fields.
  group('Bengle 0xA014 Rev-2 detector tail → snapshot fold', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    setUp(() async {
      transport = FakeBleTransport();
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
      transport.queueOnConnectResponses(v13Model: 128);
      bengle = Bengle(transport: transport);
      await bengle.onConnect();
      expect(bengle.isBengle, isTrue);
    });

    tearDown(() => transport.dispose());

    test('a Rev-2 estimator frame populates the detector keys (in toJson)',
        () async {
      final snapshots = <MachineSnapshot>[];
      final sub = bengle.currentSnapshot.listen(snapshots.add);
      await pumpEventQueue();

      bengle.debugInjectEstimator(_est(_golden0xA014V2));
      await pumpEventQueue();
      transport.subscribers[Endpoint.bengleShotSample.uuid]!(_golden0xA013);
      await pumpEventQueue();

      final snap = snapshots.last;
      expect(snap.detEventCount, 2);
      expect(snap.detLastEventT, closeTo(30.0, 1e-9));
      expect(snap.detLastEventMag, closeTo(0.45, 1e-9));
      expect(snap.detLastEventConc, closeTo(0.85, 1e-9));
      // The base fused fields (offsets 0–15) still fold through unchanged.
      expect(snap.fusedR1, closeTo(1.77, 1e-9));

      final json = snap.toJson();
      for (final k in _detKeys) {
        expect(json.containsKey(k), isTrue, reason: '$k must be present');
      }
      expect(json['detEventCount'], 2);
      expect(json['detLastEventConc'], closeTo(0.85, 1e-9));

      await sub.cancel();
    });

    test('a Rev-1 (16-byte) frame leaves the detector keys null and omitted',
        () async {
      final snapshots = <MachineSnapshot>[];
      final sub = bengle.currentSnapshot.listen(snapshots.add);
      await pumpEventQueue();

      // The legacy 16-byte estimator frame carries no Rev-2 tail.
      bengle.debugInjectEstimator(_est(_golden0xA014));
      await pumpEventQueue();
      transport.subscribers[Endpoint.bengleShotSample.uuid]!(_golden0xA013);
      await pumpEventQueue();

      final snap = snapshots.last;
      // Fused fields DID populate (an estimator frame arrived)…
      expect(snap.fusedR1, closeTo(1.77, 1e-9));
      // …but the detector tail stays null.
      expect(snap.detEventCount, isNull);
      expect(snap.detLastEventT, isNull);
      expect(snap.detLastEventMag, isNull);
      expect(snap.detLastEventConc, isNull);
      final json = snap.toJson();
      for (final k in _detKeys) {
        expect(json.containsKey(k), isFalse, reason: '$k must be omitted');
      }

      await sub.cancel();
    });
  });
}
