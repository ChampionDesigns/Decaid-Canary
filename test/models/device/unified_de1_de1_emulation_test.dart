import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_emulation_reporter.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/non_de1_profile_step.dart';

const _bengleModel = 128;

const _profile = Profile(
  version: '2',
  title: 'emulation',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  steps: [
    ProfileStepPressure(
      name: 'pour',
      pressure: 9.0,
      seconds: 30,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.fast,
      volume: 0,
    ),
    ProfileStepFlow(
      name: 'decline',
      flow: 2.0,
      seconds: 20,
      temperature: 90,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.smooth,
      volume: 0,
    ),
  ],
  targetVolumeCountStart: 0,
  tankTemperature: 0,
);

const _featureCapsAddress = 0x00803970;

bool _isMmrReadOf(FakeBleWrite w, int address) =>
    w.characteristicUUID == Endpoint.readFromMMR.uuid &&
    w.data[1] == (address >> 16) & 0xFF &&
    w.data[2] == (address >> 8) & 0xFF &&
    w.data[3] == address & 0xFF;

List<Uint8List> _tails(FakeBleTransport transport, Profile profile) => transport
    .writes
    .where(
      (w) =>
          w.characteristicUUID == Endpoint.frameWrite.uuid &&
          w.data.length == 8 &&
          w.data[0] == profile.steps.length,
    )
    .map((w) => w.data)
    .toList();

List<int> _tailWith(Profile profile, int de1Emulation) => [
  profile.steps.length,
  0,
  0,
  de1Emulation,
  0,
  0,
  0,
  0,
];

Future<(Bengle, FakeBleTransport)> _connectBengle() async {
  final transport = FakeBleTransport();
  addTearDown(transport.dispose);
  transport.queuePaletteHydrationResponses();
  transport.queueOnConnectResponses(v13Model: _bengleModel);
  final bengle = Bengle(transport: transport);
  await bengle.onConnect();
  return (bengle, transport);
}

Future<(UnifiedDe1, FakeBleTransport)> _connectDe1({required int model}) async {
  final transport = FakeBleTransport();
  addTearDown(transport.dispose);
  final de1 = UnifiedDe1(transport: transport);
  transport.queueOnConnectResponses(v13Model: model);
  await de1.onConnect();
  return (de1, transport);
}

void main() {
  group('tail frame DE1 emulation byte', () {
    for (final (flag, expected) in [(true, 1), (false, 0)]) {
      test('a Bengle with flag $flag writes data[3] = $expected', () async {
        final (bengle, transport) = await _connectBengle();
        transport.writes.clear();
        final profile = _profile.copyWith(de1Emulation: flag);

        await bengle.setProfile(profile);

        final tails = _tails(transport, profile);
        expect(tails, hasLength(1));
        expect(tails.single, _tailWith(profile, expected));
        expect(de1EmulationSentBy(bengle), expected == 1);
      });
    }

    test('a Bengle writes 0 for a profile with a step that is not pressure '
        'or flow', () async {
      final (bengle, transport) = await _connectBengle();
      transport.writes.clear();
      final profile = _profile.copyWith(
        steps: [..._profile.steps, const NonDe1ProfileStep()],
        de1Emulation: true,
      );

      await bengle.setProfile(profile);

      expect(_tails(transport, profile).single, _tailWith(profile, 0));
      expect(de1EmulationSentBy(bengle), isFalse);
      expect(profile.de1Emulation, isTrue);
    });

    for (final (label, model) in [
      ('a stock DE1', 1),
      ('a DE1 device on Bengle hardware', _bengleModel),
    ]) {
      test('$label never sets the byte', () async {
        final (de1, transport) = await _connectDe1(model: model);
        transport.writes.clear();
        final profile = _profile.copyWith(de1Emulation: true);

        await de1.setProfile(profile);

        expect(_tails(transport, profile).single, _tailWith(profile, 0));
        expect(de1EmulationSentBy(de1), isFalse);
      });
    }

    test('the device reports the byte of the last tail it wrote', () async {
      final (bengle, _) = await _connectBengle();
      expect(de1EmulationSentBy(bengle), isFalse);

      await bengle.setProfile(_profile.copyWith(de1Emulation: true));
      expect(de1EmulationSentBy(bengle), isTrue);

      await bengle.setProfile(_profile);
      expect(de1EmulationSentBy(bengle), isFalse);
    });

    test('a device without the report is never emulated', () {
      expect(de1EmulationSentBy(MockBengle()), isFalse);
      expect(de1EmulationSentBy(null), isFalse);
    });

    test('a flag change uploads the profile again', () async {
      final (bengle, transport) = await _connectBengle();
      transport.writes.clear();

      await bengle.setProfile(_profile);
      await bengle.setProfile(_profile);
      await bengle.setProfile(_profile.copyWith(de1Emulation: true));

      final tails = _tails(transport, _profile);
      expect(tails, hasLength(2));
      expect(tails[0][3], 0);
      expect(tails[1][3], 1);
    });
  });

  group('connect', () {
    test('a Bengle does not read the FeatureCaps register', () async {
      final (bengle, transport) = await _connectBengle();
      expect(
        transport.writes.where((w) => _isMmrReadOf(w, _featureCapsAddress)),
        isEmpty,
      );
      expect(
        bengle.machineInfo.extra.containsKey('de1EmulationSupported'),
        isFalse,
      );
    });

    test('a DE1 does not read the FeatureCaps register', () async {
      final (de1, transport) = await _connectDe1(model: 1);
      expect(
        transport.writes.where((w) => _isMmrReadOf(w, _featureCapsAddress)),
        isEmpty,
      );
      expect(
        de1.machineInfo.extra.containsKey('de1EmulationSupported'),
        isFalse,
      );
    });

    test('a simulated Bengle reports no support key', () {
      expect(
        MockBengle().machineInfo.extra.containsKey('de1EmulationSupported'),
        isFalse,
      );
    });
  });
}
