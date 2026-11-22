import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/parsers/profile_v2_parser.dart';
import 'package:reaprime/src/import/parsers/tcl_profile_parser.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_hash.dart';

import '../../helpers/non_de1_profile_step.dart';

Map<String, dynamic> _bundledJson() =>
    jsonDecode(File('assets/defaultProfiles/7g_basket.json').readAsStringSync())
        as Map<String, dynamic>;

Profile _withSteps(List<ProfileStep> steps) =>
    Profile.fromJson(_bundledJson()).copyWith(steps: steps, de1Emulation: true);

void main() {
  group('Profile.de1Emulation', () {
    test('defaults to false when the key is absent', () {
      final profile = Profile.fromJson(_bundledJson());
      expect(profile.de1Emulation, isFalse);
    });

    test('is true only for a JSON true', () {
      for (final value in [false, 1, 'true', null, <String, dynamic>{}]) {
        final json = _bundledJson()..['de1_emulation'] = value;
        expect(
          Profile.fromJson(json).de1Emulation,
          isFalse,
          reason: 'de1_emulation: $value',
        );
      }
      final json = _bundledJson()..['de1_emulation'] = true;
      expect(Profile.fromJson(json).de1Emulation, isTrue);
    });

    test('round-trips true through toJson and fromJson', () {
      final on = Profile.fromJson(_bundledJson()).copyWith(de1Emulation: true);
      final json = on.toJson();
      expect(json['de1_emulation'], isTrue);
      final parsed = Profile.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(parsed.de1Emulation, isTrue);
      expect(parsed, on);
    });

    test('toJson omits the key when false', () {
      final off = Profile.fromJson(_bundledJson());
      expect(off.toJson().containsKey('de1_emulation'), isFalse);
      final cleared = off
          .copyWith(de1Emulation: true)
          .copyWith(de1Emulation: false);
      expect(cleared.toJson().containsKey('de1_emulation'), isFalse);
    });

    test('a bundled profile keeps its hash and toJson bytes', () {
      final profile = Profile.fromJson(_bundledJson());
      expect(
        ProfileHash.calculateProfileHash(profile),
        'profile:1bec85b46616fd97e60e',
      );
      expect(
        sha256.convert(utf8.encode(jsonEncode(profile.toJson()))).toString(),
        '4b2a9cebcef999f3584e25fe22c9e5eaf55a7dd40d72bc11149247bacf169c5b',
      );
    });

    test('the flag changes the profile hash and equality', () {
      final off = Profile.fromJson(_bundledJson());
      final on = off.copyWith(de1Emulation: true);
      expect(on, isNot(off));
      expect(
        ProfileHash.calculateProfileHash(on),
        isNot(ProfileHash.calculateProfileHash(off)),
      );
      expect(
        ProfileHash.calculateMetadataHash(on),
        ProfileHash.calculateMetadataHash(off),
      );
    });

    test('copyWith keeps the flag when not given', () {
      final on = Profile.fromJson(_bundledJson()).copyWith(de1Emulation: true);
      expect(on.copyWith(title: 'renamed').de1Emulation, isTrue);
      expect(on.adjustTemperature(1).de1Emulation, isTrue);
    });
  });

  group('DE1 emulation step rule', () {
    test('a pressure and flow profile runs as DE1 with machine support', () {
      final profile = Profile.fromJson(_bundledJson())
          .copyWith(de1Emulation: true);
      expect(profile.steps, isNotEmpty);
      expect(profile.de1EmulationAllowedBySteps, isTrue);
      expect(profile.usesDe1Emulation(machineSupported: true), isTrue);
      expect(profile.usesDe1Emulation(machineSupported: false), isFalse);
    });

    test('the flag off never runs as DE1', () {
      final profile = Profile.fromJson(_bundledJson());
      expect(profile.usesDe1Emulation(machineSupported: true), isFalse);
    });

    test('a step that is not pressure or flow blocks the emulation', () {
      final pressureAndFlow = Profile.fromJson(_bundledJson()).steps;
      final profile = _withSteps([
        ...pressureAndFlow,
        const NonDe1ProfileStep(),
      ]);
      expect(profile.de1EmulationAllowedBySteps, isFalse);
      expect(profile.usesDe1Emulation(machineSupported: true), isFalse);
    });

    test('a blocked profile keeps its stored flag', () {
      final profile = _withSteps([const NonDe1ProfileStep()]);
      expect(profile.de1Emulation, isTrue);
      expect(profile.toJson()['de1_emulation'], isTrue);
      expect(profile.copyWith(title: 'renamed').de1Emulation, isTrue);
    });

    test('a profile without steps is not blocked', () {
      expect(_withSteps(const []).de1EmulationAllowedBySteps, isTrue);
    });
  });

  group('import', () {
    test('a TCL profile imports with the flag off', () async {
      final content = await File(
        'test/fixtures/de1app/profiles/legacy_lever.tcl',
      ).readAsString();
      expect(TclProfileParser.parse(content).profile.de1Emulation, isFalse);
    });

    test('a v2 JSON profile without the key imports with the flag off', () {
      final json = jsonDecode(
        File('test/fixtures/de1app/profiles_v2/best_practice.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(ProfileV2Parser.parse(json).profile.de1Emulation, isFalse);
    });

    test('a v2 JSON profile with de1_emulation true imports with it on', () {
      final json = jsonDecode(
        File('test/fixtures/de1app/profiles_v2/best_practice.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>..['de1_emulation'] = true;
      expect(ProfileV2Parser.parse(json).profile.de1Emulation, isTrue);
    });
  });
}
