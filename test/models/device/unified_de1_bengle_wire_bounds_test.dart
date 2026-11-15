import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

class _UnifiedProbe extends UnifiedDe1 {
  _UnifiedProbe({required super.transport});

  Future<void> poke(MMRItem item, int raw) {
    if (item.kind == MmrValueKind.scaledFloat) {
      // ignore: invalid_use_of_protected_member
      return writeMmrScaled(item, raw / item.writeScale);
    }
    // ignore: invalid_use_of_protected_member
    return writeMmrInt(item, raw);
  }
}

class _Setter {
  const _Setter(this.label, this.item, this.write, this.de1Wire, this.bengle);

  final String label;
  final MMRItem item;
  final Future<void> Function(UnifiedDe1 device) write;
  final int de1Wire;
  final int bengle;
}

final _setters = <_Setter>[
  _Setter(
    'setTankTempThreshold(90)',
    MMRItem.tankTemp,
    (d) => d.setTankTempThreshold(90),
    90,
    60,
  ),
  _Setter(
    'setSteamFlow(6)',
    MMRItem.targetSteamFlow,
    (d) => d.setSteamFlow(6),
    600,
    400,
  ),
  _Setter(
    'setFlushTemperature(105)',
    MMRItem.flushTemp,
    (d) => d.setFlushTemperature(105),
    1050,
    990,
  ),
  _Setter(
    'setHotWaterFlow(10)',
    MMRItem.hotWaterFlowRate,
    (d) => d.setHotWaterFlow(10),
    100,
    80,
  ),
];

const _overRange = <MMRItem, int>{
  MMRItem.tankTemp: 90,
  MMRItem.heaterUp1Flow: 3,
  MMRItem.heaterUp2Flow: 120,
  MMRItem.waterHeaterIdleTemp: 1200,
  MMRItem.targetSteamFlow: 30,
  MMRItem.steamStartSecs: 5,
  MMRItem.heaterUp2Timeout: 400,
  MMRItem.flushFlowRate: 5,
  MMRItem.flushTemp: 1000,
  MMRItem.flushTimeout: 3000,
  MMRItem.hotWaterFlowRate: 100,
  MMRItem.steamPurgeMode: 2,
  MMRItem.allowUSBCharging: 2,
  MMRItem.appFeatureFlags: 16777216,
  MMRItem.refillKitPresent: 3,
  MMRItem.userPresent: 2,
};

int _clampToBengle(MMRItem item, int raw) {
  final bound = bengleMmrItemBounds[item]!;
  return raw.clamp(bound.min!, bound.max!);
}

List<int> _mmrWritesTo(FakeBleTransport transport, int address) {
  return [
    for (final entry in transport.writes)
      if (entry.characteristicUUID == Endpoint.writeToMMR.uuid &&
          entry.data[1] == (address >> 16) & 0xFF &&
          entry.data[2] == (address >> 8) & 0xFF &&
          entry.data[3] == address & 0xFF)
        ByteData.sublistView(Uint8List.fromList(entry.data.sublist(4, 8)))
            .getUint32(0, Endian.little),
  ];
}

Future<_UnifiedProbe> _connectedUnified(
  FakeBleTransport transport, {
  required int v13Model,
}) async {
  transport.queueOnConnectResponses(v13Model: v13Model);
  final device = _UnifiedProbe(transport: transport);
  await device.onConnect();
  addTearDown(device.dispose);
  transport.writes.clear();
  return device;
}

void main() {
  test('the over-range table covers every Bengle bound row', () {
    expect(_overRange.keys.toSet(), bengleMmrItemBounds.keys.toSet());
  });

  for (final v13Model in const [128, 129]) {
    group('a UnifiedDe1 on a Bengle wire model ($v13Model) uses the '
        'Bengle bounds', () {
      for (final s in _setters) {
        test('${s.label} sends ${s.bengle}', () async {
          final transport = FakeBleTransport();
          final device = await _connectedUnified(transport, v13Model: v13Model);
          expect(device.isBengle, isTrue);

          await s.write(device);

          expect(_mmrWritesTo(transport, s.item.address), [s.bengle]);
        });
      }

      for (final entry in _overRange.entries) {
        final item = entry.key;
        final raw = entry.value;
        final expected = _clampToBengle(item, raw);
        test('${item.name} $raw is sent as $expected', () async {
          final transport = FakeBleTransport();
          final device = await _connectedUnified(transport, v13Model: v13Model);

          await device.poke(item, raw);

          expect(expected, isNot(raw));
          expect(_mmrWritesTo(transport, item.address), [expected]);
        });
      }
    });
  }

  group('a UnifiedDe1 on a stock DE1 wire model keeps the DE1 bounds', () {
    for (final s in _setters) {
      test('${s.label} sends ${s.de1Wire}', () async {
        final transport = FakeBleTransport();
        final device = await _connectedUnified(transport, v13Model: 3);
        expect(device.isBengle, isFalse);

        await s.write(device);

        expect(_mmrWritesTo(transport, s.item.address), [s.de1Wire]);
      });
    }

    for (final entry in _overRange.entries) {
      test('${entry.key.name} ${entry.value} goes to the wire '
          'unchanged', () async {
        final transport = FakeBleTransport();
        final device = await _connectedUnified(transport, v13Model: 3);

        await device.poke(entry.key, entry.value);

        expect(_mmrWritesTo(transport, entry.key.address), [entry.value]);
      });
    }
  });
}
