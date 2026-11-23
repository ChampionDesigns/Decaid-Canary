import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/errors.dart';

import '../../helpers/fake_ble_transport.dart';

const _bengleModel = 128;
const _blockSlots = [21, 22, 23];

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('assets/defaultProfiles/$name').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _example() => {
  'version': 1,
  'pump_curve': [
    {'pressure': 1.0, 'flow': 20.0},
    {'pressure': 3.0, 'flow': 12.0},
    {'pressure': 6.0, 'flow': 6.0},
    {'pressure': 9.0, 'flow': 5.0},
    {'pressure': 12.0, 'flow': 4.0},
  ],
  'flow_tau': 0.5,
  'flow_mode': 'both',
  'pressure_tau': 0.5,
  'pressure_mode': 'both',
  'ramp_factor': 1.0,
};

Profile _profile({
  String file = '7g_basket.json',
  Map<String, dynamic>? shaping,
  bool withShaping = true,
  bool de1Emulation = false,
}) {
  final json = _json(file)..['de1_emulation'] = de1Emulation;
  if (withShaping) json['native_shaping'] = shaping ?? _example();
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

Profile _withSteps(Profile profile, int count) => profile.copyWith(
  steps: [
    for (var i = 0; i < count; i++) profile.steps[i % profile.steps.length],
  ],
);

List<FakeBleWrite> _profileWrites(FakeBleTransport transport) => transport
    .writes
    .where((w) => w.characteristicUUID != Endpoint.readFromMMR.uuid)
    .toList();

void main() {
  group('step limit', () {
    test('a Bengle uploads a 20-step profile with the tail at 20 and the '
        'block at 21-23', () async {
      final (bengle, transport) = await _connectBengle();
      final profile = _withSteps(_profile(), 20);

      await bengle.setProfile(profile);

      final kinds = _profileWrites(transport)
          .map((w) => _kind(w, profile))
          .toList();
      expect(_collapsed(kinds), [
        'header',
        'frame',
        'extension',
        'block21',
        'block22',
        'block23',
        'tail',
        'tank',
      ]);
      expect(kinds.where((k) => k == 'frame'), hasLength(20));
      expect(_frames(transport).map((w) => w.data[0]).where((i) => i < 32), [
        for (var i = 0; i < 20; i++) i,
        21,
        22,
        23,
        20,
      ]);
    });

    test('a DE1 uploads a 20-step profile with no block', () async {
      final (de1, transport) = await _connectDe1(model: 1);
      final profile = _withSteps(_profile(), 20);

      await de1.setProfile(profile);

      final kinds = _profileWrites(transport)
          .map((w) => _kind(w, profile))
          .toList();
      expect(_collapsed(kinds), [
        'header',
        'frame',
        'extension',
        'tail',
        'tank',
      ]);
      expect(kinds.where((k) => k == 'frame'), hasLength(20));
    });

    for (final (machine, connect) in [
      ('Bengle', () async => await _connectBengle()),
      ('DE1', () async => await _connectDe1(model: 1)),
    ]) {
      test('a $machine refuses a 21-step profile with no write', () async {
        final (device, transport) = await connect();
        final profile = _withSteps(_profile(), 21);

        await expectLater(
          device.setProfile(profile),
          throwsA(
            isA<ProfileModeUnsupportedException>().having(
              (e) => e.message,
              'message',
              'Profile "${profile.title}" has 21 steps; the machine runs at '
                  'most 20 steps.',
            ),
          ),
        );

        expect(transport.writes, isEmpty);
      });
    }
  });

  group('native shaping block upload', () {
    test(
      'a Bengle writes Ben\'s first values to slots 21, 22 and 23',
      () async {
        final (bengle, transport) = await _connectBengle();

        await bengle.setProfile(_profile());

        expect(_blockWrites(transport), {
          21: _hex('01 05 19 19 32 0A C8'),
          22: _hex('1E 78 3C 3C 5A 32 78'),
          23: _hex('28 00 00 00 00 00 00'),
        });
      },
    );

    test('the block goes after the extension frames and before the tail '
        'and the tank temperature', () async {
      final (bengle, transport) = await _connectBengle();
      final profile = _profile();

      await bengle.setProfile(profile);

      final kinds = transport.writes
          .where((w) => w.characteristicUUID != Endpoint.readFromMMR.uuid)
          .map((w) => _kind(w, profile))
          .toList();
      expect(_collapsed(kinds), [
        'header',
        'frame',
        'extension',
        'block21',
        'block22',
        'block23',
        'tail',
        'tank',
      ]);
      expect(kinds.where((k) => k.startsWith('block')), hasLength(3));
    });

    test('a stock DE1 writes nothing to slots 21-23', () async {
      final (de1, transport) = await _connectDe1(model: 1);

      await de1.setProfile(_profile());

      expect(_blockWrites(transport), isEmpty);
      expect(_frames(transport), isNotEmpty);
    });

    test('a DE1 device with a Bengle model follows the Bengle wire format and '
        'writes the block', () async {
      final (de1, transport) = await _connectDe1(model: _bengleModel);

      await de1.setProfile(_profile());

      expect(de1.isBengle, isTrue);
      expect(_blockWrites(transport).keys, _blockSlots);
    });

    test(
      'a Bengle with DE1 emulation on for pump steps writes no block',
      () async {
        final (bengle, transport) = await _connectBengle();
        final profile = _profile(de1Emulation: true);

        await bengle.setProfile(profile);

        expect(_blockWrites(transport), isEmpty);
        final tail = _frames(transport)
            .singleWhere((w) => w.data[0] == profile.steps.length);
        expect(tail.data[3], 1);
      },
    );

    test(
      'a Bengle writes no block for a profile without native_shaping',
      () async {
        final (bengle, transport) = await _connectBengle();

        await bengle.setProfile(_profile(withShaping: false));

        expect(_blockWrites(transport), isEmpty);
      },
    );

    test(
      'a Bengle writes the block for DE1 emulation on with a lever step',
      () async {
        final (bengle, transport) = await _connectBengle();
        final profile = _profile(
          file: 'lever_classic_demo.json',
          de1Emulation: true,
        );

        await bengle.setProfile(profile);

        expect(_blockWrites(transport).keys, _blockSlots);
        final tail = _frames(transport)
            .singleWhere((w) => w.data[0] == profile.steps.length);
        expect(tail.data[3], 0);
      },
    );

    test('a one-point curve fills slots 22 and 23 with zeros', () async {
      final (bengle, transport) = await _connectBengle();

      await bengle.setProfile(
        _profile(
          shaping: {
            ..._example(),
            'pump_curve': [
              {'pressure': 1.0, 'flow': 20.0},
            ],
          },
        ),
      );

      expect(_blockWrites(transport), {
        21: _hex('01 01 19 19 32 0A C8'),
        22: _hex('00 00 00 00 00 00 00'),
        23: _hex('00 00 00 00 00 00 00'),
      });
    });
  });
}
