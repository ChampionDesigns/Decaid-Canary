import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

YamlMap _load(String path) =>
    loadYaml(File(path).readAsStringSync()) as YamlMap;

YamlMap _schemas(YamlMap spec) =>
    (spec['components'] as YamlMap)['schemas'] as YamlMap;

String _sensorSchemaText(YamlMap spec, String name) =>
    _schemas(spec)[name].toString();

const _rest = 'assets/api/rest_v1.yml';
const _ws = 'assets/api/websocket_v1.yml';

void main() {
  group('ShotSnapshot.sensors in rest_v1.yml', () {
    late YamlMap sensors;

    setUp(() {
      final shot = _schemas(_load(_rest))['ShotSnapshot'] as YamlMap;
      sensors = (shot['properties'] as YamlMap)['sensors'] as YamlMap;
    });

    test('is an optional object of channel maps keyed by sensor id', () {
      final shot = _schemas(_load(_rest))['ShotSnapshot'] as YamlMap;
      expect(shot['required'] ?? const [], isNot(contains('sensors')));
      expect(sensors['type'], 'object');
      final channelMap = sensors['additionalProperties'];
      expect(channelMap, isA<YamlMap>());
      expect((channelMap as YamlMap)['type'], 'object');
    });

    test('channel values may be null', () {
      final channelMap = sensors['additionalProperties'] as YamlMap;
      final value = channelMap['additionalProperties'] as YamlMap;
      expect(value['nullable'], isTrue);
    });

    test('gives a puck-estimator example', () {
      final example = sensors['example'] as YamlMap;
      expect(example.keys.single, endsWith('-puckestimator'));
      expect((example.values.single as YamlMap)['timestamp'], isA<String>());
    });

    test('types each channel by its manifest entry', () {
      final text = sensors['description'].toString().replaceAll(
        RegExp(r'\s+'),
        ' ',
      );
      expect(text, isNot(contains('other channels listed there are numbers')));
      for (final type in [
        'number',
        'integer',
        'string',
        'boolean',
        'object',
        'array',
      ]) {
        expect(text, contains(type), reason: type);
      }
    });

    test('states when the property is omitted', () {
      expect(
        sensors['description'].toString().replaceAll(RegExp(r'\s+'), ' '),
        contains('Omitted when the sample holds no sensor frame.'),
      );
    });
  });

  group('puck-estimator sensor in the sensor schemas', () {
    final channels = RegExp(r"DataChannel\(\s*key: '(\w+)'")
        .allMatches(
          File(
            'lib/src/models/device/impl/bengle/bengle_puck_estimator.dart',
          ).readAsStringSync(),
        )
        .map((m) => m.group(1)!)
        .toList();

    test('the channel list is read from the sensor source', () {
      expect(
        channels,
        containsAll(['timestamp', 'r1', 'hydraulicPowerMeasured']),
      );
      expect(channels, hasLength(17));
    });

    for (final (path, names) in [
      (_rest, ['SensorManifest', 'SensorSnapshot']),
      (_ws, ['SensorSnapshot']),
    ]) {
      for (final name in names) {
        test('$path $name names the puckestimator id and channels', () {
          final text = _sensorSchemaText(_load(path), name);
          final flat = text.replaceAll(RegExp(r'\s+'), ' ');
          expect(text, contains('-puckestimator'));
          expect(flat, contains('`timestamp` (string)'));
          expect(
            flat,
            contains('Every channel except `timestamp` is a number'),
          );
          for (final key in channels) {
            expect(text, contains(RegExp('\\b$key\\b')), reason: key);
          }
        });
      }
    }
  });
}
