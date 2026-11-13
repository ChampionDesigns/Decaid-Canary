import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

class _De1Probe extends UnifiedDe1 {
  _De1Probe({required super.transport});

  Future<void> poke(MMRItem item, int raw) => _poke(this, item, raw);
}

class _BengleProbe extends Bengle {
  _BengleProbe({required super.transport});

  Future<void> poke(MMRItem item, int raw) => _poke(this, item, raw);
}

Future<void> _poke(UnifiedDe1 device, MMRItem item, int raw) {
  if (item.kind == MmrValueKind.scaledFloat) {
    // ignore: invalid_use_of_protected_member
    return device.writeMmrScaled(item, raw / item.writeScale);
  }
  // ignore: invalid_use_of_protected_member
  return device.writeMmrInt(item, raw);
}

class _Row {
  const _Row(this.item, this.raw, this.bengleWire);

  final MMRItem item;
  final int raw;
  final int bengleWire;
}

const _rows = <_Row>[
  _Row(MMRItem.tankTemp, 90, 60),
  _Row(MMRItem.heaterUp1Flow, 3, 5),
  _Row(MMRItem.heaterUp2Flow, 120, 80),
  _Row(MMRItem.waterHeaterIdleTemp, 1200, 1000),
  _Row(MMRItem.targetSteamFlow, 30, 40),
  _Row(MMRItem.steamStartSecs, 5, 10),
  _Row(MMRItem.heaterUp2Timeout, 400, 300),
  _Row(MMRItem.flushFlowRate, 5, 10),
  _Row(MMRItem.flushTemp, 1000, 990),
  _Row(MMRItem.flushTimeout, 3000, 2500),
  _Row(MMRItem.hotWaterFlowRate, 100, 80),
  _Row(MMRItem.steamPurgeMode, 2, 1),
  _Row(MMRItem.allowUSBCharging, 2, 1),
  _Row(MMRItem.appFeatureFlags, 16777216, 16777215),
  _Row(MMRItem.refillKitPresent, 3, 2),
  _Row(MMRItem.userPresent, 2, 1),
];

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
  group('a DE1 keeps the shared MMRItem bounds', () {
    for (final row in _rows) {
      test('${row.item.name} ${row.raw} goes to the wire unchanged', () async {
        final transport = FakeBleTransport()..queueOnConnectResponses();
        final de1 = _De1Probe(transport: transport);
        await de1.onConnect();
        addTearDown(de1.dispose);
        transport.writes.clear();

        await de1.poke(row.item, row.raw);

        expect(_mmrWritesTo(transport, row.item.address), [row.raw]);
      });
    }
  });

  group('a Bengle clamps to the contract effective bound', () {
    for (final row in _rows) {
      test(
        '${row.item.name} ${row.raw} is sent as ${row.bengleWire}',
        () async {
          final transport = FakeBleTransport()
            ..queueOnConnectResponses(v13Model: 128)
            ..queuePaletteHydrationResponses();
          final bengle = _BengleProbe(transport: transport);
          await bengle.onConnect();
          addTearDown(bengle.dispose);
          transport.writes.clear();

          await bengle.poke(row.item, row.raw);

          expect(_mmrWritesTo(transport, row.item.address), [row.bengleWire]);
        },
      );
    }
  });
}
