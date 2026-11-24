import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

const _bengleModel = 128;
const _blockSlots = [21, 22, 23, 24];

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('assets/defaultProfiles/$name').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _shaping({
  double pressureRamp = 0.5,
  double flowRamp = 0.5,
  double filter = 0.0,
}) => {
  'pump_curve': [
    {'pressure': 1.0, 'flow': 20.0},
    {'pressure': 3.0, 'flow': 12.0},
    {'pressure': 6.0, 'flow': 6.0},
    {'pressure': 9.0, 'flow': 5.0},
    {'pressure': 12.0, 'flow': 4.0},
  ],
  'flow_tau': 0.5,
  'pressure_tau': 0.5,
  'pressure_filter_tau': filter,
  'pressure_ramp_tau': pressureRamp,
  'flow_ramp_tau': flowRamp,
};

Profile _profile({
  String file = '7g_basket.json',
  Map<String, dynamic>? shaping,
  bool de1Emulation = false,
}) {
  final json = _json(file)
    ..['de1_emulation'] = de1Emulation
    ..['native_shaping'] = shaping ?? _shaping();
  return Profile.fromJson(json);
}

Future<(Bengle, FakeBleTransport)> _connectBengle() async {
  final transport = FakeBleTransport();
  addTearDown(transport.dispose);
  transport.queuePaletteHydrationResponses();
  transport.queueOnConnectResponses(
    v13Model: _bengleModel,
    profileModeCaps: 0x7,
  );
  final bengle = Bengle(transport: transport);
  await bengle.onConnect();
  await transport.completeNativeShapeConnectRead();
  transport.writes.clear();
  return (bengle, transport);
}

Future<(UnifiedDe1, FakeBleTransport)> _connectDe1({required int model}) async {
  final transport = FakeBleTransport();
  addTearDown(transport.dispose);
  transport.queueOnConnectResponses(v13Model: model, profileModeCaps: 0x7);
  final de1 = UnifiedDe1(transport: transport);
  await de1.onConnect();
  transport.writes.clear();
  return (de1, transport);
}

Iterable<FakeBleWrite> _frames(FakeBleTransport transport) => transport.writes
    .where((w) => w.characteristicUUID == Endpoint.frameWrite.uuid);

Map<int, List<int>> _blockWrites(FakeBleTransport transport) => {
  for (final w in _frames(transport))
    if (_blockSlots.contains(w.data[0])) w.data[0]: w.data.sublist(1),
};

List<int> _hex(String bytes) =>
    bytes.split(' ').map((b) => int.parse(b, radix: 16)).toList();

String _kind(FakeBleWrite w, Profile profile) {
  if (w.characteristicUUID == Endpoint.headerWrite.uuid) return 'header';
  if (w.characteristicUUID == Endpoint.writeToMMR.uuid) {
    final address = w.data[1] << 16 | w.data[2] << 8 | w.data[3];
    return address == MMRItem.tankTemp.address ? 'tank' : 'mmr';
  }
  if (w.characteristicUUID != Endpoint.frameWrite.uuid) return 'other';
  final index = w.data[0];
  final steps = profile.steps.length;
  if (index < steps) return 'frame';
  if (index == steps) return 'tail';
  if (_blockSlots.contains(index)) return 'block$index';
  if (index >= 32) return 'extension';
  return 'unexpected$index';
}

List<String> _collapsed(List<String> kinds) => [
  for (final (i, kind) in kinds.indexed)
    if (i == 0 || kinds[i - 1] != kind) kind,
];

List<String> _profileKinds(FakeBleTransport transport, Profile profile) =>
    transport.writes
        .where((w) => w.characteristicUUID != Endpoint.readFromMMR.uuid)
        .map((w) => _kind(w, profile))
        .toList();

void main() {
  group('native shaping block version 2 upload', () {
    for (final (id, shaping, slot21, slot24) in [
      ('G2', _shaping(), '02 05 19 19 19 0A C8', '00 19 00 00 00 00 00'),
      (
        'G3',
        _shaping(filter: 0.5),
        '02 05 19 19 19 0A C8',
        '19 19 00 00 00 00 00',
      ),
      (
        'G4',
        _shaping(pressureRamp: 1.0, flowRamp: 0),
        '02 05 19 19 32 0A C8',
        '00 00 00 00 00 00 00',
      ),
    ]) {
      test('a Bengle writes vector $id to slots 21-24', () async {
        final (bengle, transport) = await _connectBengle();

        await bengle.setProfile(_profile(shaping: shaping));

        expect(_blockWrites(transport), {
          21: _hex(slot21),
          22: _hex('1E 78 3C 3C 5A 32 78'),
          23: _hex('28 00 00 00 00 00 00'),
          24: _hex(slot24),
        });
      });
    }

    test('G2: the order is header, frames, extension, 21, 22, 23, 24, tail '
        'and tank temperature', () async {
      final (bengle, transport) = await _connectBengle();
      final profile = _profile();

      await bengle.setProfile(profile);

      final kinds = _profileKinds(transport, profile);
      expect(_collapsed(kinds), [
        'header',
        'frame',
        'extension',
        'block21',
        'block22',
        'block23',
        'block24',
        'tail',
        'tank',
      ]);
      for (final slot in _blockSlots) {
        expect(kinds.where((k) => k == 'block$slot'), hasLength(1));
      }
    });

    test('all time settings at 0 still write version 2 and slot 24', () async {
      final (bengle, transport) = await _connectBengle();

      await bengle.setProfile(
        _profile(shaping: _shaping(pressureRamp: 0, flowRamp: 0)),
      );

      final writes = _blockWrites(transport);
      expect(writes.keys, _blockSlots);
      expect(writes[21]!.first, 2);
      expect(writes[24], _hex('00 00 00 00 00 00 00'));
    });

    test('a block with only defaults writes version 2 and slot 24', () async {
      final (bengle, transport) = await _connectBengle();

      await bengle.setProfile(_profile(shaping: const {}));

      final writes = _blockWrites(transport);
      expect(writes.keys, _blockSlots);
      expect(writes[21], _hex('02 00 00 00 00 00 00'));
    });

    test('a stock DE1 writes nothing to slots 21-24', () async {
      final (de1, transport) = await _connectDe1(model: 1);

      await de1.setProfile(_profile());

      expect(_blockWrites(transport), isEmpty);
      expect(_frames(transport), isNotEmpty);
    });

    test('a Bengle with DE1 emulation byte 1 in the tail writes nothing to '
        'slots 21-24', () async {
      final (bengle, transport) = await _connectBengle();
      final profile = _profile(de1Emulation: true);

      await bengle.setProfile(profile);

      expect(_blockWrites(transport), isEmpty);
      final tail = _frames(transport)
          .singleWhere((w) => w.data[0] == profile.steps.length);
      expect(tail.data[3], 1);
    });
  });
}
