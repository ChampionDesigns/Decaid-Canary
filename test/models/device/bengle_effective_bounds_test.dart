import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

typedef _Write = Future<void> Function(Bengle bengle);

class _Case {
  const _Case(this.label, this.address, this.write, this.expectedWire);

  final String label;
  final int address;
  final _Write write;
  final int expectedWire;
}

Future<Bengle> _connectedBengle(FakeBleTransport transport) async {
  final bengle = Bengle(transport: transport);
  await bengle.onConnect();
  addTearDown(bengle.dispose);
  transport.writes.clear();
  return bengle;
}

List<int> _mmrWritesTo(FakeBleTransport transport, int address) {
  return [
    for (final entry in transport.writes)
      if (entry.characteristicUUID == Endpoint.writeToMMR.uuid &&
          entry.data[1] == (address >> 16) & 0xFF &&
          entry.data[2] == (address >> 8) & 0xFF &&
          entry.data[3] == address & 0xFF)
        ByteData.sublistView(
          Uint8List.fromList(entry.data.sublist(4, 8)),
        ).getUint32(0, Endian.little),
  ];
}

void main() {
  final cases = <_Case>[
    _Case(
      'EndOfShotWeight max 3000 g',
      BengleScaleMmr.endOfShotWeight.address,
      (b) => b.setStopAtWeightTarget(5000),
      300000,
    ),
    _Case(
      'SetLocalTimeOfWeek max 604799 s',
      BengleMmr.setLocalTimeOfWeek.address,
      (b) => b.pushFirmwareWakeSchedule(
        secondsSinceSundayLocal: 604800,
        windows: const [],
      ),
      604799,
    ),
    _Case(
      'TankTemp max 60',
      MMRItem.tankTemp.address,
      (b) => b.setTankTempThreshold(90),
      60,
    ),
    _Case(
      'TankTemp min 0',
      MMRItem.tankTemp.address,
      (b) => b.setTankTempThreshold(-5),
      0,
    ),
    _Case(
      'HeaterUp1Flow min 0.5 ml/s',
      MMRItem.heaterUp1Flow.address,
      (b) => b.setHeaterPhase1Flow(0.1),
      5,
    ),
    _Case(
      'HeaterUp2Flow max 8 ml/s',
      MMRItem.heaterUp2Flow.address,
      (b) => b.setHeaterPhase2Flow(12),
      80,
    ),
    _Case(
      'WaterHeaterIdleTemp max 100 degC',
      MMRItem.waterHeaterIdleTemp.address,
      (b) => b.setHeaterIdleTemp(120),
      1000,
    ),
    _Case(
      'HeaterUp2Timeout max 30 s',
      MMRItem.heaterUp2Timeout.address,
      (b) => b.setHeaterPhase2Timeout(45),
      300,
    ),
    _Case(
      'TargetSteamFlow min 0.4 ml/s',
      MMRItem.targetSteamFlow.address,
      (b) => b.setSteamFlow(0.1),
      40,
    ),
    _Case(
      'TargetSteamFlow max 4 ml/s',
      MMRItem.targetSteamFlow.address,
      (b) => b.setSteamFlow(6),
      400,
    ),
    _Case(
      'FlushFlowRate min 1 ml/s',
      MMRItem.flushFlowRate.address,
      (b) => b.setFlushFlow(0),
      10,
    ),
    _Case(
      'FlushTemp max 99 degC',
      MMRItem.flushTemp.address,
      (b) => b.setFlushTemperature(105),
      990,
    ),
    _Case(
      'FlushTimeout max 250 s',
      MMRItem.flushTimeout.address,
      (b) => b.setFlushTimeout(400),
      2500,
    ),
    _Case(
      'HotWaterFlowRate max 8 ml/s',
      MMRItem.hotWaterFlowRate.address,
      (b) => b.setHotWaterFlow(10),
      80,
    ),
    _Case(
      'SteamPurgeMode max 1',
      MMRItem.steamPurgeMode.address,
      (b) => b.setSteamPurgeMode(7),
      1,
    ),
  ];

  group('Bengle writes clamp to the firmware effective bound', () {
    for (final c in cases) {
      test(c.label, () async {
        final transport = FakeBleTransport()
          ..queueOnConnectResponses(v13Model: 128)
          ..queuePaletteHydrationResponses();
        final bengle = await _connectedBengle(transport);

        await c.write(bengle);

        expect(_mmrWritesTo(transport, c.address), [c.expectedWire]);
      });
    }

    test('RefillKitPresent keeps the re-detect value 2', () async {
      final transport = FakeBleTransport()
        ..queueOnConnectResponses(v13Model: 128)
        ..queuePaletteHydrationResponses();
      final bengle = await _connectedBengle(transport);

      await bengle.setRefillKitSettings(De1RefillKitSettings.auto);

      expect(_mmrWritesTo(transport, MMRItem.refillKitPresent.address), [2]);
    });

    test('HeaterV is not clamped: unset never becomes a set voltage', () async {
      final transport = FakeBleTransport()
        ..queueOnConnectResponses(v13Model: 128)
        ..queuePaletteHydrationResponses();
      final bengle = await _connectedBengle(transport);

      await bengle.setHeaterVoltage(De1HeaterVoltage.unset);

      expect(MMRItem.heaterV.min, isNull);
      expect(MMRItem.heaterV.max, isNull);
      expect(_mmrWritesTo(transport, MMRItem.heaterV.address), [0xFFFFFFFF]);
    });
  });

  group('declared effective bounds (raw wire units)', () {
    test('rows without a public over-range writer', () {
      expect(
        [BengleMmr.scaleCalCmd.min, BengleMmr.scaleCalCmd.max],
        [0, 3],
        reason: 'ScaleCalCmd 4 and 5 end in the Error step (System.cpp:2427)',
      );
      expect(
        [BengleMmr.scaleCalWeight.min, BengleMmr.scaleCalWeight.max],
        [10, 100000],
        reason: 'ScaleCalWeight model bound 1..10000 g, x10 on the wire',
      );
      expect(
        [MMRItem.steamStartSecs.min, MMRItem.steamStartSecs.max],
        [10, 400],
      );
      expect(
        [MMRItem.allowUSBCharging.min, MMRItem.allowUSBCharging.max],
        [0, 1],
      );
      expect(
        [MMRItem.appFeatureFlags.min, MMRItem.appFeatureFlags.max],
        [0, 0x7FFFFFFF],
      );
      expect(
        [MMRItem.refillKitPresent.min, MMRItem.refillKitPresent.max],
        [0, 2],
      );
      expect([MMRItem.userPresent.min, MMRItem.userPresent.max], [0, 1]);
    });
  });
}
