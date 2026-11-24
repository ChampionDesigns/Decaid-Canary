import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/native_shaping.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_hash.dart';

Map<String, dynamic> _bundledJson() =>
    jsonDecode(File('assets/defaultProfiles/7g_basket.json').readAsStringSync())
        as Map<String, dynamic>;

const _curve = [
  {'pressure': 1.0, 'flow': 20.0},
  {'pressure': 3.0, 'flow': 12.0},
  {'pressure': 6.0, 'flow': 6.0},
  {'pressure': 9.0, 'flow': 5.0},
  {'pressure': 12.0, 'flow': 4.0},
];

Map<String, dynamic> _settings({
  double pressureRamp = 0.5,
  double flowRamp = 0.5,
  double filter = 0.0,
}) => {
  'version': 2,
  'pump_curve': _curve,
  'flow_tau': 0.5,
  'flow_mode': 'both',
  'pressure_tau': 0.5,
  'pressure_mode': 'both',
  'pressure_filter_tau': filter,
  'pressure_ramp_tau': pressureRamp,
  'flow_ramp_tau': flowRamp,
};

const _timeKeys = [
  'flow_tau',
  'pressure_tau',
  'pressure_filter_tau',
  'pressure_ramp_tau',
  'flow_ramp_tau',
];

List<int> _hex(String bytes) =>
    bytes.split(' ').map((b) => int.parse(b, radix: 16)).toList();

List<int> _vector(String slot21, String slot24) => [
  ..._hex(slot21),
  ..._hex('1E 78 3C 3C 5A 32 78'),
  ..._hex('28 00 00 00 00 00 00'),
  ..._hex(slot24),
];

final _g2 = _vector('02 05 19 19 19 0A C8', '00 19 00 00 00 00 00');
final _g3 = _vector('02 05 19 19 19 0A C8', '19 19 00 00 00 00 00');
final _g4 = _vector('02 05 19 19 32 0A C8', '00 00 00 00 00 00 00');
final _g1 = [
  ..._hex('01 05 19 19 32 0A C8'),
  ..._hex('1E 78 3C 3C 5A 32 78'),
  ..._hex('28 00 00 00 00 00 00'),
];
final _b1 = _vector('02 05 19 19 FB 0A C8', '00 19 00 00 00 00 00');
final _b2 = _vector('02 05 19 19 19 0A C8', '00 FB 00 00 00 00 00');
final _b3 = _vector('02 05 19 19 19 0A C8', '00 19 01 00 00 00 00');
final _b4 = _vector('02 05 19 19 19 0A C8', 'FB 19 00 00 00 00 00');
final _b5 = _vector('03 05 19 19 19 0A C8', '00 19 00 00 00 00 00');
final _o1 = _vector('02 05 19 19 FB 0A C8', 'FB 19 00 00 00 00 00');
final _o2 = _vector('02 05 19 19 19 0A C8', '00 FB 01 00 00 00 00');

Matcher _refuses(String text) => throwsA(
  isA<ArgumentError>().having((e) => e.message, 'message', contains(text)),
);

const _tauRange = 'pressure_filter_tau';
const _unusedBytes = 'unused bytes';

List<int> _report(List<int> block, {int source = 1, int flags = 0}) => [
  source,
  0,
  7,
  flags,
  ...block,
  ...List.filled(28 - block.length, 0),
];

void main() {
  group('the five time settings in JSON', () {
    for (final key in _timeKeys) {
      test('$key: 0.5 s is written as 0.5', () {
        final shaping = NativeShaping.fromJson({key: 0.5});

        expect(shaping.toJson()[key], 0.5);
      });

      test('$key: 0 is written as 0, also when the key is absent', () {
        final absent = NativeShaping.fromJson(const {});
        final zero = NativeShaping.fromJson({key: 0});

        expect(absent.toJson()[key], 0.0);
        expect(zero, absent);
        expect(zero.toJson(), absent.toJson());
      });

      test('$key: 5 s is accepted; 5.02 s and -0.02 s are refused', () {
        expect(NativeShaping.fromJson({key: 5}).toJson()[key], 5.0);
        expect(() => NativeShaping.fromJson({key: 5.02}), _refuses(key));
        expect(() => NativeShaping.fromJson({key: -0.02}), _refuses(key));
        expect(() => NativeShaping.fromJson({key: 'fast'}), _refuses(key));
      });

      test('$key: rounds to the 0.02 s step half up', () {
        expect(NativeShaping.fromJson({key: 0.51}).toJson()[key], 0.52);
        expect(NativeShaping.fromJson({key: 0.509}).toJson()[key], 0.5);
        expect(NativeShaping.fromJson({key: 0.29}).toJson()[key], 0.3);
      });
    }

    test('toJson writes every key with version 2', () {
      expect(NativeShaping.fromJson(const {}).toJson().keys.toSet(), {
        'version',
        'pump_curve',
        'flow_tau',
        'flow_mode',
        'pressure_tau',
        'pressure_mode',
        ..._timeKeys.skip(2),
      });
      expect(NativeShaping.fromJson(const {}).toJson()['version'], 2);
    });

    test('accepts version 2 or no version, and refuses 1 and 3', () {
      expect(
        NativeShaping.fromJson(_settings()),
        NativeShaping.fromJson({..._settings()}..remove('version')),
      );
      for (final version in [1, 3]) {
        expect(
          () => NativeShaping.fromJson({..._settings(), 'version': version}),
          _refuses('version'),
        );
      }
    });

    test('refuses ramp_factor and names the keys that replace it', () {
      expect(
        () => NativeShaping.fromJson({..._settings(), 'ramp_factor': 1.0}),
        _refuses('pressure_ramp_tau'),
      );
      expect(NativeShaping.hasRetiredKey({'ramp_factor': 1.0}), isTrue);
      expect(NativeShaping.hasRetiredKey(_settings()), isFalse);
    });
  });

  group('profile hash with the new time settings', () {
    Profile shapedWith(Map<String, dynamic> block) =>
        Profile.fromJson(_bundledJson()..['native_shaping'] = block);

    test('an explicit 0 hashes the same as no key', () {
      final withoutKeys = {..._settings()}
        ..remove('pressure_filter_tau')
        ..remove('flow_ramp_tau');
      expect(
        ProfileHash.calculateProfileHash(
          shapedWith(_settings(pressureRamp: 0.5, flowRamp: 0)),
        ),
        ProfileHash.calculateProfileHash(shapedWith(withoutKeys)),
      );
    });

    test('each time setting above 0 gives a new hash', () {
      final base = ProfileHash.calculateProfileHash(
        shapedWith(_settings(pressureRamp: 0, flowRamp: 0)),
      );
      final hashes = {
        base,
        ProfileHash.calculateProfileHash(
          shapedWith(_settings(pressureRamp: 0, flowRamp: 0, filter: 0.5)),
        ),
        ProfileHash.calculateProfileHash(
          shapedWith(_settings(pressureRamp: 0.5, flowRamp: 0)),
        ),
        ProfileHash.calculateProfileHash(
          shapedWith(_settings(pressureRamp: 0, flowRamp: 0.5)),
        ),
      };
      expect(hashes, hasLength(4));
    });
  });

  group('block version 2 (firmware vectors)', () {
    test('G2 encodes to the exact 28 bytes and decodes to the settings', () {
      final shaping = NativeShaping.fromJson(_settings());

      expect(shaping.toBlockBytes(), _g2);
      final decoded = NativeShaping.fromBlockBytes(_g2);
      expect(decoded, shaping);
      expect(decoded.flowTau, 0.5);
      expect(decoded.pressureTau, 0.5);
      expect(decoded.pressureRampTau, 0.5);
      expect(decoded.flowRampTau, 0.5);
      expect(decoded.pressureFilterTau, 0.0);
    });

    test('G3 encodes to the exact bytes and decodes to a 0.5 s filter', () {
      final shaping = NativeShaping.fromJson(_settings(filter: 0.5));

      expect(shaping.toBlockBytes(), _g3);
      expect(NativeShaping.fromBlockBytes(_g3), shaping);
      expect(NativeShaping.fromBlockBytes(_g3).pressureFilterTau, 0.5);
    });

    test('G4 encodes to the exact bytes: pressure ramp 1.0, flow ramp 0', () {
      final shaping = NativeShaping.fromJson(
        _settings(pressureRamp: 1.0, flowRamp: 0),
      );

      expect(shaping.toBlockBytes(), _g4);
      final decoded = NativeShaping.fromBlockBytes(_g4);
      expect(decoded, shaping);
      expect(decoded.pressureRampTau, 1.0);
      expect(decoded.flowRampTau, 0.0);
    });

    test('G1 (version 1) is refused for the version', () {
      expect(() => NativeShaping.fromBlockBytes(_g1), _refuses('version'));
      expect(
        () => NativeShaping.fromBlockBytes([..._g1, ...List.filled(7, 0)]),
        _refuses('version'),
      );
    });

    test('B1 is refused for the pressure ramp range', () {
      expect(
        () => NativeShaping.fromBlockBytes(_b1),
        _refuses('pressure_ramp_tau'),
      );
    });

    test('B2 is refused for the flow ramp range', () {
      expect(
        () => NativeShaping.fromBlockBytes(_b2),
        _refuses('flow_ramp_tau'),
      );
    });

    test('B3 is refused for unused bytes', () {
      expect(() => NativeShaping.fromBlockBytes(_b3), _refuses(_unusedBytes));
    });

    test('B4 is refused for the filter range', () {
      expect(() => NativeShaping.fromBlockBytes(_b4), _refuses(_tauRange));
    });

    test('B5 (version 3) is refused for the version', () {
      expect(() => NativeShaping.fromBlockBytes(_b5), _refuses('version'));
    });

    test('O1 is refused for the filter range: tau before ramp', () {
      expect(() => NativeShaping.fromBlockBytes(_o1), _refuses(_tauRange));
    });

    test('O2 is refused for the flow ramp range: ramp before unused', () {
      expect(
        () => NativeShaping.fromBlockBytes(_o2),
        _refuses('flow_ramp_tau'),
      );
    });

    test('the time constants are checked in the order b2, b3, b21', () {
      final all = List.of(_g2)
        ..[2] = 0xFB
        ..[3] = 0xFB
        ..[21] = 0xFB;
      final pressureAndFilter = List.of(_g2)
        ..[3] = 0xFB
        ..[21] = 0xFB;

      expect(() => NativeShaping.fromBlockBytes(all), _refuses('flow_tau'));
      expect(
        () => NativeShaping.fromBlockBytes(pressureAndFilter),
        _refuses('pressure_tau'),
      );
    });

    test('the ramps are checked in the order b4, b22', () {
      final both = List.of(_g2)
        ..[4] = 0xFB
        ..[22] = 0xFB;

      expect(
        () => NativeShaping.fromBlockBytes(both),
        _refuses('pressure_ramp_tau'),
      );
    });

    test('a block that is not 28 bytes is refused', () {
      expect(
        () => NativeShaping.fromBlockBytes(_g2.sublist(0, 21)),
        throwsArgumentError,
      );
      expect(
        () => NativeShaping.fromBlockBytes([..._g2, 0]),
        throwsArgumentError,
      );
      expect(() => NativeShaping.fromBlockBytes([]), throwsArgumentError);
    });
  });

  group('reg 66 report with block version 2', () {
    test('G3 at bytes 4-31 gives a 0.5 s filter and both ramps', () {
      final report = NativeShapingReport.fromBytes(_report(_g3));

      expect(report.source, NativeShapingSource.profile);
      expect(report.settings, NativeShaping.fromJson(_settings(filter: 0.5)));
      final json = report.toJson()['settings'] as Map;
      expect(json['pressure_filter_tau'], 0.5);
      expect(json['pressure_ramp_tau'], 0.5);
      expect(json['flow_ramp_tau'], 0.5);
    });

    test('G2 gives a filter of 0, written as 0', () {
      final report = NativeShapingReport.fromBytes(_report(_g2));

      expect(report.settings?.pressureFilterTau, 0.0);
      expect((report.toJson()['settings'] as Map)['pressure_filter_tau'], 0.0);
    });

    test('G1 (version 1) gives no settings', () {
      final report = NativeShapingReport.fromBytes(_report(_g1));

      expect(report.source, NativeShapingSource.profile);
      expect(report.settings, isNull);
    });

    test('B1-B5, O1 and O2 give no settings', () {
      for (final (id, block) in [
        ('B1', _b1),
        ('B2', _b2),
        ('B3', _b3),
        ('B4', _b4),
        ('B5', _b5),
        ('O1', _o1),
        ('O2', _o2),
      ]) {
        expect(
          NativeShapingReport.fromBytes(_report(block)).settings,
          isNull,
          reason: id,
        );
      }
    });

    test('fromJson agrees with fromBytes for G3', () {
      final fromBytes = NativeShapingReport.fromBytes(_report(_g3));
      final json =
          jsonDecode(jsonEncode(fromBytes.toJson())) as Map<String, dynamic>;

      expect(NativeShapingReport.fromJson(json), fromBytes);
    });
  });

  group('pump curve checks in the firmware order', () {
    const mixed = [
      {'pressure': 1.0, 'flow': 20.1},
      {'pressure': 0.4, 'flow': 10.0},
    ];
    final mixedBlock = [
      ..._hex('02 02 19 19 19 0A C9'),
      ..._hex('04 64 00 00 00 00 00'),
      ..._hex('00 00 00 00 00 00 00'),
      ..._hex('00 19 00 00 00 00 00'),
    ];

    test('JSON: a flow range fault at point 0 wins over a pressure range '
        'fault at point 1', () {
      expect(
        () => NativeShaping.fromJson({..._settings(), 'pump_curve': mixed}),
        _refuses('pump_curve[0].flow'),
      );
    });

    test('block: the same mixed curve is refused for the flow at point 0', () {
      expect(
        () => NativeShaping.fromBlockBytes(mixedBlock),
        _refuses('pump_curve[0].flow'),
      );
    });

    test('a pressure rise fault at point 1 wins over a flow range fault at '
        'point 1', () {
      expect(
        () => NativeShaping.fromJson({
          ..._settings(),
          'pump_curve': const [
            {'pressure': 6.0, 'flow': 10.0},
            {'pressure': 6.2, 'flow': 20.5},
          ],
        }),
        _refuses('pump_curve[1].pressure'),
      );
    });
  });
}
