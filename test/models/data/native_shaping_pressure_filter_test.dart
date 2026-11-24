import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/native_shaping.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_hash.dart';

Map<String, dynamic> _bundledJson() =>
    jsonDecode(File('assets/defaultProfiles/7g_basket.json').readAsStringSync())
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

List<int> _hex(String bytes) =>
    bytes.split(' ').map((b) => int.parse(b, radix: 16)).toList();

List<int> _block(String slot21, [String? slot24]) => [
  ..._hex(slot21),
  ..._hex('1E 78 3C 3C 5A 32 78'),
  ..._hex('28 00 00 00 00 00 00'),
  if (slot24 != null) ..._hex(slot24),
];

final _case1 = _block('02 05 19 19 32 0A C8', '19 00 00 00 00 00 00');
final _case2 = _block('01 05 19 19 32 0A C8');
final _case3 = _block('02 05 19 19 32 0A C8', '19 01 00 00 00 00 00');
final _case4 = _block('02 05 19 19 32 0A C8', 'FB 00 00 00 00 00 00');
final _case5 = _block('03 05 19 19 32 0A C8', '19 00 00 00 00 00 00');

Matcher _refuses(String text) => throwsA(
  isA<ArgumentError>().having((e) => e.message, 'message', contains(text)),
);

List<int> _report(List<int> block, {int source = 1}) => [
  source,
  0,
  7,
  0,
  ...block,
  ...List.filled(28 - block.length, 0),
];

void main() {
  group('pressure_filter_tau in JSON', () {
    test('0.5 s is written as the key 0.5', () {
      final shaping = NativeShaping.fromJson({
        ..._example(),
        'pressure_filter_tau': 0.5,
      });

      expect(shaping.pressureFilterTau, 0.5);
      expect(shaping.toJson()['pressure_filter_tau'], 0.5);
    });

    test('0 is not written', () {
      final shaping = NativeShaping.fromJson(_example());

      expect(shaping.pressureFilterTau, 0.0);
      expect(shaping.toJson().containsKey('pressure_filter_tau'), isFalse);
      expect(shaping.toJson(), _example());
    });

    test('an explicit 0 gives the same object and JSON as no key', () {
      final withZero = NativeShaping.fromJson({
        ..._example(),
        'pressure_filter_tau': 0,
      });
      final without = NativeShaping.fromJson(_example());

      expect(withZero, without);
      expect(withZero.toJson(), without.toJson());
      expect(withZero.toJson().containsKey('pressure_filter_tau'), isFalse);
    });

    test('5.02 and -0.02 are refused with an ArgumentError', () {
      expect(
        () => NativeShaping.fromJson({'pressure_filter_tau': 5.02}),
        _refuses('pressure_filter_tau'),
      );
      expect(
        () => NativeShaping.fromJson({'pressure_filter_tau': -0.02}),
        _refuses('pressure_filter_tau'),
      );
      expect(
        () => NativeShaping.fromJson({'pressure_filter_tau': 'fast'}),
        _refuses('pressure_filter_tau'),
      );
    });

    test('rounds to the 0.02 s step half up, as pressure_tau does', () {
      for (final raw in [0.51, 0.509, 0.29, 5.009, 0.009, 0.01]) {
        final shaping = NativeShaping.fromJson({
          'pressure_tau': raw,
          'pressure_filter_tau': raw,
        });
        expect(
          shaping.pressureFilterTau,
          shaping.pressureTau,
          reason: 'raw $raw',
        );
      }
      expect(
        NativeShaping.fromJson({'pressure_filter_tau': 0.51}).pressureFilterTau,
        0.52,
      );
      expect(
        NativeShaping.fromJson({'pressure_filter_tau': 0.509})
            .pressureFilterTau,
        0.5,
      );
    });

    test('the version is 1 when the filter is 0 and 2 when it is above 0', () {
      expect(NativeShaping.fromJson(_example()).version, 1);
      expect(
        NativeShaping.fromJson({..._example(), 'pressure_filter_tau': 0.5})
            .toJson()['version'],
        2,
      );
    });

    test('accepts version 1 or 2 in JSON and stores the canonical form', () {
      final v2Zero = NativeShaping.fromJson({..._example(), 'version': 2});
      expect(v2Zero, NativeShaping.fromJson(_example()));
      expect(v2Zero.toJson()['version'], 1);

      final v1Filter = NativeShaping.fromJson({
        ..._example(),
        'pressure_filter_tau': 0.5,
      });
      expect(v1Filter.version, 2);
      expect(
        NativeShaping.fromJson(
          jsonDecode(jsonEncode(v1Filter.toJson())) as Map<String, dynamic>,
        ),
        v1Filter,
      );
    });

    test('refuses version 3 in JSON', () {
      expect(
        () => NativeShaping.fromJson({..._example(), 'version': 3}),
        _refuses('version'),
      );
    });
  });

  group('profile hash with pressure_filter_tau', () {
    Profile shapedWith(Map<String, dynamic> block) =>
        Profile.fromJson(_bundledJson()..['native_shaping'] = block);

    test('an explicit 0 hashes the same as no key', () {
      expect(
        ProfileHash.calculateProfileHash(
          shapedWith({..._example(), 'pressure_filter_tau': 0}),
        ),
        ProfileHash.calculateProfileHash(shapedWith(_example())),
      );
    });

    test('a value above 0 gives a new hash', () {
      expect(
        ProfileHash.calculateProfileHash(
          shapedWith({..._example(), 'pressure_filter_tau': 0.5}),
        ),
        isNot(ProfileHash.calculateProfileHash(shapedWith(_example()))),
      );
    });
  });

  group('block version 2 (firmware byte vectors)', () {
    test('case 1 encodes to the exact 28 bytes and decodes to 0.5 s', () {
      final shaping = NativeShaping.fromJson({
        ..._example(),
        'pressure_filter_tau': 0.5,
      });

      expect(shaping.toBlockBytes(), _case1);
      expect(NativeShaping.fromBlockBytes(_case1).pressureFilterTau, 0.5);
      expect(NativeShaping.fromBlockBytes(_case1), shaping);
    });

    test('case 2 encodes to the exact 21 bytes and decodes to 0', () {
      final shaping = NativeShaping.fromJson(_example());

      expect(shaping.toBlockBytes(), _case2);
      expect(NativeShaping.fromBlockBytes(_case2).pressureFilterTau, 0.0);
      expect(NativeShaping.fromBlockBytes(_case2), shaping);
    });

    test('case 3 is refused for unused bytes', () {
      expect(() => NativeShaping.fromBlockBytes(_case3), _refuses('unused'));
    });

    test('case 4 is refused for the filter range', () {
      expect(
        () => NativeShaping.fromBlockBytes(_case4),
        _refuses('pressure_filter_tau'),
      );
    });

    test('case 5 is refused for the version', () {
      expect(() => NativeShaping.fromBlockBytes(_case5), _refuses('version'));
    });

    test('version 2 with a filter of 0 decodes to the case 2 settings', () {
      final v2Zero = _block('02 05 19 19 32 0A C8', '00 00 00 00 00 00 00');

      expect(
        NativeShaping.fromBlockBytes(v2Zero),
        NativeShaping.fromBlockBytes(_case2),
      );
      expect(NativeShaping.fromBlockBytes(v2Zero).toBlockBytes(), _case2);
    });

    test('a block length that does not match its version is refused', () {
      expect(
        () => NativeShaping.fromBlockBytes(_case1.sublist(0, 21)),
        throwsArgumentError,
      );
      expect(
        () => NativeShaping.fromBlockBytes([..._case2, ...List.filled(7, 0)]),
        throwsArgumentError,
      );
      expect(() => NativeShaping.fromBlockBytes([]), throwsArgumentError);
    });

    test('checks the filter range before the unused bytes', () {
      expect(
        () => NativeShaping.fromBlockBytes(
          _block('02 05 19 19 32 0A C8', 'FB 01 00 00 00 00 00'),
        ),
        _refuses('pressure_filter_tau'),
      );
    });
  });

  group('reg 66 report with block version 2', () {
    test('the case 1 block at bytes 4-31 gives 0.5 s', () {
      final report = NativeShapingReport.fromBytes(_report(_case1));

      expect(report.source, NativeShapingSource.profile);
      expect(report.settings?.pressureFilterTau, 0.5);
      expect((report.toJson()['settings'] as Map)['pressure_filter_tau'], 0.5);
    });

    test('the version 1 vector gives 0', () {
      final report = NativeShapingReport.fromBytes(_report(_case2));

      expect(report.settings?.pressureFilterTau, 0.0);
      expect(
        (report.toJson()['settings'] as Map).containsKey('pressure_filter_tau'),
        isFalse,
      );
    });

    test('a refused version 2 block gives no settings', () {
      expect(NativeShapingReport.fromBytes(_report(_case3)).settings, isNull);
      expect(NativeShapingReport.fromBytes(_report(_case4)).settings, isNull);
      expect(NativeShapingReport.fromBytes(_report(_case5)).settings, isNull);
    });

    test('fromJson agrees with fromBytes for a version 2 block', () {
      final fromBytes = NativeShapingReport.fromBytes(_report(_case1));
      final json =
          jsonDecode(jsonEncode(fromBytes.toJson())) as Map<String, dynamic>;

      expect(NativeShapingReport.fromJson(json), fromBytes);
    });
  });
}
