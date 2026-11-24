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
  'version': 2,
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
  'pressure_filter_tau': 0.0,
  'pressure_ramp_tau': 1.0,
  'flow_ramp_tau': 0.0,
};

const _exampleBlock = [
  0x02, 0x05, 0x19, 0x19, 0x32, 0x0A, 0xC8, //
  0x1E, 0x78, 0x3C, 0x3C, 0x5A, 0x32, 0x78, //
  0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

Map<String, dynamic> _withCurve(List<List<num>> points) => {
  ..._example(),
  'pump_curve': [
    for (final point in points) {'pressure': point[0], 'flow': point[1]},
  ],
};

Matcher _refuses(String field) => throwsA(
  isA<ArgumentError>().having((e) => e.message, 'message', contains(field)),
);

List<int> _report({
  int source = 1,
  int rule = 0,
  int latch = 7,
  int flags = 0,
  List<int> block = _exampleBlock,
}) => [source, rule, latch, flags, ...block];

void main() {
  group('NativeShaping.fromJson', () {
    test('round-trips the example and encodes the example bytes', () {
      final shaping = NativeShaping.fromJson(_example());

      expect(shaping.toJson(), _example());
      expect(
        NativeShaping.fromJson(
          jsonDecode(jsonEncode(shaping.toJson())) as Map<String, dynamic>,
        ),
        shaping,
      );
      expect(shaping.toBlockBytes(), _exampleBlock);
      expect(NativeShaping.fromBlockBytes(_exampleBlock), shaping);
    });

    test('absent keys inside the block take the defaults', () {
      final shaping = NativeShaping.fromJson({});

      expect(shaping.toJson(), {
        'version': 2,
        'pump_curve': <dynamic>[],
        'flow_tau': 0.0,
        'flow_mode': 'both',
        'pressure_tau': 0.0,
        'pressure_mode': 'both',
        'pressure_filter_tau': 0.0,
        'pressure_ramp_tau': 0.0,
        'flow_ramp_tau': 0.0,
      });
      expect(
        NativeShaping.fromJson({'flow_tau': 0.4, 'pressure_mode': 'rise'})
            .toJson(),
        {
          'version': 2,
          'pump_curve': <dynamic>[],
          'flow_tau': 0.4,
          'flow_mode': 'both',
          'pressure_tau': 0.0,
          'pressure_mode': 'rise',
          'pressure_filter_tau': 0.0,
          'pressure_ramp_tau': 0.0,
          'flow_ramp_tau': 0.0,
        },
      );
    });

    test('rounds each number to its wire step, half up', () {
      final shaping = NativeShaping.fromJson({
        ..._withCurve([
          [2.96, 19.94],
          [5.04, 11.96],
        ]),
        'flow_tau': 0.509,
        'pressure_tau': 0.51,
        'pressure_ramp_tau': 1.009,
        'flow_ramp_tau': 0.29,
      });

      expect(shaping.flowTau, 0.5);
      expect(shaping.pressureTau, 0.52);
      expect(shaping.pressureRampTau, 1.0);
      expect(shaping.flowRampTau, 0.3);
      expect(shaping.pumpCurve.map((p) => p.toJson()), [
        {'pressure': 3.0, 'flow': 19.9},
        {'pressure': 5.0, 'flow': 12.0},
      ]);
    });

    test('rounds a decimal half step up, whatever its binary product', () {
      for (final (raw, rounded) in [
        (0.29, 0.3),
        (0.57, 0.58),
        (1.13, 1.14),
        (1.15, 1.16),
        (2.01, 2.02),
        (2.03, 2.04),
        (0.01, 0.02),
      ]) {
        final shaping = NativeShaping.fromJson({
          'flow_tau': raw,
          'pressure_tau': raw,
          'pressure_filter_tau': raw,
          'pressure_ramp_tau': raw,
          'flow_ramp_tau': raw,
        });
        expect(shaping.flowTau, rounded, reason: 'flow_tau $raw');
        expect(shaping.pressureTau, rounded, reason: 'pressure_tau $raw');
        expect(
          shaping.pressureFilterTau,
          rounded,
          reason: 'pressure_filter_tau $raw',
        );
        expect(
          shaping.pressureRampTau,
          rounded,
          reason: 'pressure_ramp_tau $raw',
        );
        expect(shaping.flowRampTau, rounded, reason: 'flow_ramp_tau $raw');
      }
      for (var tenths = 5; tenths < 135; tenths++) {
        final raw = tenths / 10 + 0.05;
        final shaping = NativeShaping.fromJson(
          _withCurve([
            [raw, raw > 20 ? 20 : raw],
          ]),
        );
        expect(
          shaping.pumpCurve.single.pressure,
          (tenths + 1) / 10,
          reason: 'pressure $raw',
        );
      }
      expect(NativeShaping.fromJson({'flow_tau': 0.2899}).flowTau, 0.28);
    });

    test('accepts a value that passes its rule only after rounding', () {
      final shaping = NativeShaping.fromJson({
        ..._withCurve([
          [0.46, 20.04],
          [0.96, 12.0],
        ]),
        'flow_tau': 5.009,
        'pressure_ramp_tau': 5.009,
        'flow_ramp_tau': 5.009,
      });

      expect(shaping.pumpCurve.first.toJson(), {'pressure': 0.5, 'flow': 20.0});
      expect(shaping.pumpCurve.last.pressure, 1.0);
      expect(shaping.flowTau, 5.0);
      expect(shaping.pressureRampTau, 5.0);
      expect(shaping.flowRampTau, 5.0);
    });

    test('checks the rounded value, not the raw value, at each limit', () {
      expect(
        NativeShaping.fromJson(
          _withCurve([
            [1.0, 20.0],
            [1.45, 12.0],
          ]),
        ).pumpCurve.last.pressure,
        1.5,
      );
      expect(
        () => NativeShaping.fromJson(
          _withCurve([
            [1.0, 20.0],
            [1.44, 12.0],
          ]),
        ),
        _refuses('pump_curve[1].pressure'),
      );
      expect(NativeShaping.fromJson({'flow_tau': 5.009}).flowTau, 5.0);
      expect(
        () => NativeShaping.fromJson({'flow_tau': 5.01}),
        _refuses('flow_tau'),
      );
      expect(
        () => NativeShaping.fromJson(
          _withCurve([
            [1.0, 20.05],
          ]),
        ),
        _refuses('pump_curve[0].flow'),
      );
    });

    group('refuses each rule with an ArgumentError', () {
      final cases = <String, (Map<String, dynamic>, String)>{
        'version 3': ({..._example(), 'version': 3}, 'version'),
        'version 0': ({..._example(), 'version': 0}, 'version'),
        'version 1': ({..._example(), 'version': 1}, 'version'),
        'version as text': ({..._example(), 'version': '2'}, 'version'),
        'pump_curve not an array': (
          {..._example(), 'pump_curve': 'off'},
          'pump_curve',
        ),
        'nine points': (
          _withCurve([
            for (var i = 0; i < 9; i++) [1.0 + i, 20.0 - i],
          ]),
          'pump_curve',
        ),
        'a point that is not an object': (
          {
            ..._example(),
            'pump_curve': [1.0],
          },
          'pump_curve[0]',
        ),
        'a point without pressure': (
          {
            ..._example(),
            'pump_curve': [
              {'flow': 20.0},
            ],
          },
          'pump_curve[0].pressure',
        ),
        'pressure below 0.5 bar': (
          _withCurve([
            [0.44, 20.0],
          ]),
          'pump_curve[0].pressure',
        ),
        'pressure above 13.5 bar': (
          _withCurve([
            [13.56, 4.0],
          ]),
          'pump_curve[0].pressure',
        ),
        'pressure rise below 0.5 bar': (
          _withCurve([
            [3.0, 12.0],
            [3.4, 11.0],
          ]),
          'pump_curve[1].pressure',
        ),
        'flow above 20 mL/s': (
          _withCurve([
            [1.0, 20.06],
          ]),
          'pump_curve[0].flow',
        ),
        'flow below 0 mL/s': (
          _withCurve([
            [1.0, -0.1],
          ]),
          'pump_curve[0].flow',
        ),
        'flow that rises': (
          _withCurve([
            [3.0, 12.0],
            [6.0, 13.0],
          ]),
          'pump_curve[1].flow',
        ),
        'flow_tau above 5 s': ({..._example(), 'flow_tau': 6}, 'flow_tau'),
        'flow_tau below 0 s': ({..._example(), 'flow_tau': -0.02}, 'flow_tau'),
        'pressure_tau above 5 s': (
          {..._example(), 'pressure_tau': 5.02},
          'pressure_tau',
        ),
        'pressure_filter_tau above 5 s': (
          {..._example(), 'pressure_filter_tau': 5.02},
          'pressure_filter_tau',
        ),
        'pressure_ramp_tau above 5 s': (
          {..._example(), 'pressure_ramp_tau': 5.02},
          'pressure_ramp_tau',
        ),
        'pressure_ramp_tau below 0 s': (
          {..._example(), 'pressure_ramp_tau': -0.02},
          'pressure_ramp_tau',
        ),
        'flow_ramp_tau above 5 s': (
          {..._example(), 'flow_ramp_tau': 5.02},
          'flow_ramp_tau',
        ),
        'flow_ramp_tau below 0 s': (
          {..._example(), 'flow_ramp_tau': -0.02},
          'flow_ramp_tau',
        ),
        'the retired ramp_factor key': (
          {..._example(), 'ramp_factor': 1.0},
          'ramp_factor',
        ),
        'unknown flow_mode': ({..._example(), 'flow_mode': 'up'}, 'flow_mode'),
        'unknown pressure_mode': (
          {..._example(), 'pressure_mode': 'BOTH'},
          'pressure_mode',
        ),
        'a number as text that is not a number': (
          {..._example(), 'flow_tau': 'fast'},
          'flow_tau',
        ),
        'a boolean for a number': (
          {..._example(), 'pressure_ramp_tau': true},
          'pressure_ramp_tau',
        ),
        'a value that is not finite': (
          {..._example(), 'pressure_tau': double.nan},
          'pressure_tau',
        ),
      };
      for (final MapEntry(key: name, value: (json, field)) in cases.entries) {
        test(name, () {
          expect(() => NativeShaping.fromJson(json), _refuses(field));
        });
      }
    });
  });

  group('NativeShaping.fromBlockBytes', () {
    List<int> withByte(int index, int value) =>
        List.of(_exampleBlock)..[index] = value;

    test('refuses a version that is not 2', () {
      for (final version in [0, 1, 3, 255]) {
        expect(
          () => NativeShaping.fromBlockBytes(withByte(0, version)),
          _refuses('version'),
          reason: 'version $version',
        );
      }
    });

    test('refuses mode code 3 and a point count above 8', () {
      expect(
        () => NativeShaping.fromBlockBytes(withByte(1, 0xC5)),
        throwsArgumentError,
      );
      expect(
        () => NativeShaping.fromBlockBytes(withByte(1, 0x39)),
        throwsArgumentError,
      );
    });

    test('refuses unused point bytes that are not 0', () {
      expect(
        () => NativeShaping.fromBlockBytes(withByte(15, 1)),
        throwsArgumentError,
      );
    });

    test('refuses the firmware vector with a flow that rises', () {
      expect(
        () => NativeShaping.fromBlockBytes(withByte(10, 0x82)),
        _refuses('pump_curve[2].flow'),
      );
    });

    test('decodes the modes from their bits', () {
      final shaping = NativeShaping.fromBlockBytes(withByte(1, 0x65));

      expect(shaping.flowMode, NativeShapingMode.rise);
      expect(shaping.pressureMode, NativeShapingMode.fall);
      expect(shaping.toBlockBytes()[1], 0x65);
    });
  });

  group('Profile.nativeShaping', () {
    test('an absent block stays absent and toJson writes no key', () {
      final profile = Profile.fromJson(_bundledJson());
      expect(profile.nativeShaping, isNull);
      expect(profile.toJson().containsKey('native_shaping'), isFalse);

      final nullJson = _bundledJson()..['native_shaping'] = null;
      expect(Profile.fromJson(nullJson).nativeShaping, isNull);
    });

    test('round-trips through toJson and fromJson', () {
      final json = _bundledJson()..['native_shaping'] = _example();
      final profile = Profile.fromJson(json);

      expect(profile.nativeShaping, NativeShaping.fromJson(_example()));
      expect(profile.toJson()['native_shaping'], _example());
      expect(
        Profile.fromJson(
          jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
        ),
        profile,
      );
    });

    test('a block that breaks a rule refuses the profile', () {
      final json = _bundledJson()
        ..['native_shaping'] = {..._example(), 'flow_tau': 6};
      expect(() => Profile.fromJson(json), _refuses('flow_tau'));

      final notAnObject = _bundledJson()..['native_shaping'] = true;
      expect(() => Profile.fromJson(notAnObject), _refuses('native_shaping'));
    });

    test('two profiles that differ only in the block are not equal', () {
      final plain = Profile.fromJson(_bundledJson());
      final shaped = plain.copyWith(
        nativeShaping: NativeShaping.fromJson(_example()),
      );
      final otherShape = plain.copyWith(
        nativeShaping: NativeShaping.fromJson({..._example(), 'flow_tau': 1}),
      );

      expect(shaped, isNot(plain));
      expect(shaped, isNot(otherShape));
    });

    test('copyWith keeps the block and can clear it', () {
      final shaped = Profile.fromJson(
        _bundledJson()..['native_shaping'] = _example(),
      );

      expect(shaped.copyWith(title: 'Other').nativeShaping, isNotNull);
      final cleared = shaped.copyWith(clearNativeShaping: true);
      expect(cleared.nativeShaping, isNull);
      expect(cleared, Profile.fromJson(_bundledJson()));
    });
  });

  group('profile hash', () {
    test('a profile without the block keeps the hash it has today', () {
      expect(
        ProfileHash.calculateProfileHash(Profile.fromJson(_bundledJson())),
        'profile:1bec85b46616fd97e60e',
      );
    });

    test('a profile that differs only in the block has a new hash', () {
      final plain = Profile.fromJson(_bundledJson());
      final shaped = plain.copyWith(
        nativeShaping: NativeShaping.fromJson(_example()),
      );
      final allDefaults = plain.copyWith(
        nativeShaping: NativeShaping.fromJson({}),
      );

      final hashes = {
        ProfileHash.calculateProfileHash(plain),
        ProfileHash.calculateProfileHash(shaped),
        ProfileHash.calculateProfileHash(allDefaults),
      };
      expect(hashes, hasLength(3));
    });

    test('two blocks that round to the same bytes hash the same', () {
      Profile shapedWith(Map<String, dynamic> block) =>
          Profile.fromJson(_bundledJson()..['native_shaping'] = block);

      final exact = shapedWith(_example());
      final near = shapedWith({
        ..._withCurve([
          [1.04, 19.96],
          [2.96, 12.04],
          [6.0, 6.0],
          [9.0, 5.0],
          [12.0, 4.0],
        ]),
        'flow_tau': 0.509,
        'pressure_tau': 0.49,
        'pressure_ramp_tau': 0.99,
      });

      expect(near, exact);
      expect(
        ProfileHash.calculateProfileHash(near),
        ProfileHash.calculateProfileHash(exact),
      );
      expect(
        ProfileHash.calculateProfileHash(shapedWith({})),
        ProfileHash.calculateProfileHash(
          shapedWith(NativeShaping.fromJson({}).toJson()),
        ),
      );
    });
  });

  group('NativeShapingReport.fromBytes', () {
    test('decodes a profile source with the example settings', () {
      final report = NativeShapingReport.fromBytes(_report());

      expect(report.source, NativeShapingSource.profile);
      expect(report.refusal, NativeShapingRefusal.none);
      expect(report.latchCount, 7);
      expect(report.settingsRounded, isFalse);
      expect(report.settings, NativeShaping.fromJson(_example()));
    });

    test('decodes a CLI source', () {
      final report = NativeShapingReport.fromBytes(_report(source: 0));

      expect(report.source, NativeShapingSource.cli);
      expect(report.settings, NativeShaping.fromJson(_example()));
    });

    test('decodes a refused block with its rule', () {
      final report = NativeShapingReport.fromBytes(
        _report(source: 2, rule: 10),
      );

      expect(report.source, NativeShapingSource.cliBlockRefused);
      expect(report.refusal, NativeShapingRefusal.flowRise);
      expect(report.toJson()['refusal'], 'flowRise');
    });

    test('decodes DE1 emulation with no settings', () {
      final report = NativeShapingReport.fromBytes(
        _report(source: 3, block: List.filled(28, 0)),
      );

      expect(report.source, NativeShapingSource.inactive);
      expect(report.settings, isNull);
      expect(report.toJson().containsKey('settings'), isFalse);
    });

    test('gives no settings in DE1 emulation even for a valid block', () {
      final report = NativeShapingReport.fromBytes(_report(source: 3));

      expect(report.source, NativeShapingSource.inactive);
      expect(report.settings, isNull);
    });

    test('reads bit 0 of the flags as rounded settings', () {
      expect(
        NativeShapingReport.fromBytes(_report(flags: 1)).settingsRounded,
        isTrue,
      );
      expect(
        NativeShapingReport.fromBytes(_report(flags: 0xFE)).settingsRounded,
        isFalse,
      );
    });

    test('reads bytes 25 and 26 as the filter and the flow ramp', () {
      final block = List.of(_exampleBlock)
        ..[21] = 0x19
        ..[22] = 0x32;

      final settings = NativeShapingReport.fromBytes(_report(block: block))
          .settings!;

      expect(settings.pressureFilterTau, 0.5);
      expect(settings.flowRampTau, 1.0);
    });

    test('gives no settings when a byte in 27-31 is not 0', () {
      for (var index = 23; index < 28; index++) {
        final block = List.of(_exampleBlock)..[index] = 1;
        expect(
          NativeShapingReport.fromBytes(_report(block: block)).settings,
          isNull,
          reason: 'report byte ${index + 4}',
        );
      }
    });

    test('gives no settings for a version 1 block', () {
      final v1Block = List.of(_exampleBlock)..[0] = 1;

      final report = NativeShapingReport.fromBytes(_report(block: v1Block));

      expect(report.source, NativeShapingSource.profile);
      expect(report.settings, isNull);
      expect(report.toJson().containsKey('settings'), isFalse);
    });

    test('keeps an unknown source or rule code as unknown', () {
      final report = NativeShapingReport.fromBytes(
        _report(source: 9, rule: 42),
      );

      expect(report.source, NativeShapingSource.unknown);
      expect(report.sourceCode, 9);
      expect(report.refusal, NativeShapingRefusal.unknown);
      expect(report.refusalCode, 42);
      expect(report.settings, NativeShaping.fromJson(_example()));
    });

    test('gives no settings for a block it cannot decode', () {
      final badBlock = List.of(_exampleBlock)..[0] = 3;

      expect(
        NativeShapingReport.fromBytes(_report(block: badBlock)).settings,
        isNull,
      );
    });

    test('refuses a length that is not 32 bytes', () {
      expect(
        () => NativeShapingReport.fromBytes(_report().sublist(0, 31)),
        throwsArgumentError,
      );
    });

    test('round-trips through JSON', () {
      for (final bytes in [
        _report(flags: 1),
        _report(source: 2, rule: 10),
        _report(source: 3, block: List.filled(28, 0)),
        _report(source: 9, rule: 42),
      ]) {
        final report = NativeShapingReport.fromBytes(bytes);
        final json =
            jsonDecode(jsonEncode(report.toJson())) as Map<String, dynamic>;
        expect(NativeShapingReport.fromJson(json), report);
      }
      expect(NativeShapingReport.fromBytes(_report()).toJson(), {
        'source': 'profile',
        'sourceCode': 1,
        'refusal': 'none',
        'refusalCode': 0,
        'latchCount': 7,
        'settingsRounded': false,
        'settings': _example(),
      });
    });

    test('tryFromJson gives null for a value it cannot read', () {
      expect(NativeShapingReport.tryFromJson(null), isNull);
      expect(NativeShapingReport.tryFromJson(true), isNull);
      expect(NativeShapingReport.tryFromJson({'sourceCode': 'x'}), isNull);
    });
  });

  group('NativeShapingReport.fromJson', () {
    Map<String, dynamic> json({int source = 1, Object? settings}) => {
      'sourceCode': source,
      'refusalCode': 0,
      'latchCount': 4,
      'settingsRounded': true,
      'settings': settings ?? _example(),
    };

    test('gives no settings for source 3, as fromBytes does', () {
      final report = NativeShapingReport.fromJson(json(source: 3));

      expect(report.source, NativeShapingSource.inactive);
      expect(report.settings, isNull);
      expect(
        report,
        NativeShapingReport.fromBytes(_report(source: 3, latch: 4, flags: 1)),
      );
    });

    test(
      'keeps the report with no settings when the settings do not parse',
      () {
        for (final settings in <Object>[
          {'flow_tau': 9},
          {'pump_curve': 'x'},
          {'flow_mode': 7},
        ]) {
          final report = NativeShapingReport.fromJson(json(settings: settings));

          expect(report.sourceCode, 1, reason: '$settings');
          expect(report.refusalCode, 0);
          expect(report.latchCount, 4);
          expect(report.settingsRounded, isTrue);
          expect(report.settings, isNull);
          expect(
            NativeShapingReport.tryFromJson(json(settings: settings)),
            report,
          );
        }
      },
    );
  });
}
