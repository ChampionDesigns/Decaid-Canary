import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_hash.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/services/database/mappers/shot_mapper.dart';

Profile _bundledProfile() => Profile.fromJson(
  jsonDecode(File('assets/defaultProfiles/7g_basket.json').readAsStringSync())
      as Map<String, dynamic>,
);

ShotRecord _shot({WorkflowMachine? machine, Profile? profile}) => ShotRecord(
  id: 'shot-1',
  timestamp: DateTime.utc(2026, 11, 18, 8),
  createdAt: DateTime.utc(2026, 11, 18, 8),
  updatedAt: DateTime.utc(2026, 11, 18, 8),
  measurements: const [],
  workflow: Workflow(
    id: 'workflow-1',
    name: 'Workflow',
    profile: profile ?? _bundledProfile().copyWith(de1Emulation: true),
    steamSettings: SteamSettings.defaults(),
    hotWaterData: HotWaterData.defaults(),
    rinseData: RinseData.defaults(),
    machine: machine,
  ),
);

const _emulated = WorkflowMachine(
  provenanceStatus: WorkflowMachineProvenanceStatus.captured,
  model: '128',
  de1Emulation: true,
);
const _native = WorkflowMachine(
  provenanceStatus: WorkflowMachineProvenanceStatus.captured,
  model: '128',
);

Map<String, dynamic> _roundTrip(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void main() {
  group('WorkflowMachine.de1Emulation', () {
    test('defaults to false and is absent from JSON when false', () {
      expect(_native.de1Emulation, isFalse);
      expect(_native.toJson().containsKey('de1Emulation'), isFalse);
    });

    test('is written as true and read back only from a JSON true', () {
      expect(_emulated.toJson()['de1Emulation'], isTrue);
      expect(WorkflowMachine.fromJson(_emulated.toJson()), _emulated);
      for (final value in [false, 1, 'true', null]) {
        expect(
          WorkflowMachine.fromJson({'de1Emulation': value}).de1Emulation,
          isFalse,
          reason: 'de1Emulation: $value',
        );
      }
    });

    test('takes part in equality', () {
      expect(_emulated == _native, isFalse);
      expect(_native.copyWith(de1Emulation: true), _emulated);
    });
  });

  group('ShotRecord de1Emulation key', () {
    test('an emulated shot has a top-level de1Emulation true', () {
      final shot = _shot(machine: _emulated);
      expect(shot.de1Emulation, isTrue);
      expect(shot.toJson()['de1Emulation'], isTrue);
      expect(shot.toJsonWithoutMeasurements()['de1Emulation'], isTrue);
    });

    test('a native shot has no de1Emulation key', () {
      for (final machine in [_native, null]) {
        final shot = _shot(machine: machine);
        expect(shot.de1Emulation, isFalse);
        expect(shot.toJson().containsKey('de1Emulation'), isFalse);
        expect(
          shot.toJsonWithoutMeasurements().containsKey('de1Emulation'),
          isFalse,
        );
      }
    });

    test('round-trips with and without the key', () {
      for (final machine in [_emulated, _native]) {
        final shot = _shot(machine: machine);
        for (final parse in [
          ShotRecord.fromJson,
          ShotRecord.fromRecordedJson,
        ]) {
          final parsed = parse(_roundTrip(shot.toJson()));
          expect(parsed.de1Emulation, shot.de1Emulation);
          expect(parsed.toJson(), _roundTrip(shot.toJson()));
        }
      }
    });

    test('a top-level true alone marks the shot as emulated', () {
      final json = _roundTrip(_shot().toJson())..['de1Emulation'] = true;
      final parsed = ShotRecord.fromJson(json);
      expect(parsed.de1Emulation, isTrue);
      expect(parsed.workflow.id, 'workflow-1');
      expect(parsed.toJson()['de1Emulation'], isTrue);
    });

    test('a top-level value that is not true is false', () {
      for (final value in [false, 1, 'true', null]) {
        final json = _roundTrip(_shot().toJson())..['de1Emulation'] = value;
        expect(
          ShotRecord.fromJson(json).de1Emulation,
          isFalse,
          reason: 'de1Emulation: $value',
        );
      }
    });

    test('an old shot without the key loads and serializes as before', () {
      final legacy = {
        'id': 'legacy-1',
        'timestamp': '2025-03-01T08:00:00.000Z',
        'createdAt': '2025-03-01T08:00:00.000Z',
        'updatedAt': '2025-03-01T08:00:00.000Z',
        'measurements': <Object?>[],
        'workflow': _roundTrip(
          _shot(profile: _bundledProfile()).workflow.toJson(),
        ),
      };
      for (final parse in [ShotRecord.fromJson, ShotRecord.fromRecordedJson]) {
        final parsed = parse(_roundTrip(legacy));
        expect(parsed.de1Emulation, isFalse);
        expect(parsed.displayProfileTitle, parsed.workflow.profile.title);
        expect(_roundTrip(parsed.toJson()), legacy);
      }
    });
  });

  group('ShotRecord.displayProfileTitle', () {
    test('prefixes the title of an emulated shot', () {
      final shot = _shot(machine: _emulated);
      expect(shot.displayProfileTitle, 'B-DE1 · 7g basket');
    });

    test('shows the plain title of a native shot', () {
      expect(_shot(machine: _native).displayProfileTitle, '7g basket');
      expect(_shot().displayProfileTitle, '7g basket');
    });

    test('never doubles the prefix', () {
      final profile = _bundledProfile().copyWith(title: 'B-DE1 · 7g basket');
      final shot = _shot(machine: _emulated, profile: profile);
      expect(shot.displayProfileTitle, 'B-DE1 · 7g basket');
    });

    test('keeps a blank title blank', () {
      for (final title in ['', '  ']) {
        final profile = _bundledProfile().copyWith(title: title);
        final shot = _shot(machine: _emulated, profile: profile);
        expect(shot.displayProfileTitle, title);
      }
    });

    test('names a live title the same way', () {
      expect(
        ShotRecord.profileTitleFor('7g basket', de1Emulation: true),
        'B-DE1 · 7g basket',
      );
      expect(
        ShotRecord.profileTitleFor('7g basket', de1Emulation: false),
        '7g basket',
      );
    });

    test('uses space, U+00B7 and space as the separator', () {
      expect(ShotRecord.de1EmulationTitlePrefix, 'B-DE1 · ');
    });
  });

  group('profile identity after an emulated shot', () {
    test('profile title and profile id do not change', () {
      final profile = _bundledProfile().copyWith(de1Emulation: true);
      final before = ProfileHash.calculateProfileHash(profile);
      final shot = _shot(machine: _emulated, profile: profile);

      expect(shot.workflow.profile.title, '7g basket');
      expect(shot.toJson()['workflow']['profile']['title'], '7g basket');
      expect(ProfileHash.calculateProfileHash(shot.workflow.profile), before);
      final parsed = ShotRecord.fromRecordedJson(_roundTrip(shot.toJson()));
      expect(parsed.workflow.profile.title, '7g basket');
      expect(ProfileHash.calculateProfileHash(parsed.workflow.profile), before);
    });

    test('the stored profileTitle column keeps the plain title', () {
      final companion = ShotMapper.toCompanion(_shot(machine: _emulated));
      expect(companion.profileTitle.value, '7g basket');
    });
  });
}
