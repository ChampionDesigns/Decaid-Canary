import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

final YamlMap _spec =
    loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;

YamlMap _schemas() => (_spec['components'] as YamlMap)['schemas'] as YamlMap;

YamlMap _resolve(YamlMap node) {
  final ref = node[r'$ref'];
  if (ref is! String) return node;
  return _schemas()[ref.split('/').last] as YamlMap;
}

YamlMap _workflowPutProfile() {
  final put = (_spec['paths'] as YamlMap)['/api/v1/workflow']['put'] as YamlMap;
  final body = _resolve(
    put['requestBody']['content']['application/json']['schema'] as YamlMap,
  );
  return _resolve((body['properties'] as YamlMap)['profile'] as YamlMap);
}

void main() {
  test('the PUT /workflow profile takes "native_shaping": null', () {
    final profile = _workflowPutProfile();
    final shaping = (profile['properties'] as YamlMap)['native_shaping'];

    expect(shaping['nullable'], isTrue);
    expect(shaping['allOf'], [
      {r'$ref': '#/components/schemas/NativeShaping'},
    ]);
    expect(shaping, isNot(contains(r'$ref')));
    expect(shaping['description'], contains('`null` removes the block'));
  });

  test('NativeShaping has pressure_filter_tau 0-5 s, default 0, and '
      'version 1 or 2', () {
    final properties =
        (_schemas()['NativeShaping'] as YamlMap)['properties'] as YamlMap;
    final filter = properties['pressure_filter_tau'] as YamlMap;

    expect(filter['type'], 'number');
    expect(filter['minimum'], 0);
    expect(filter['maximum'], 5);
    expect(filter['default'], 0);
    expect(filter['description'], contains('step 0.02'));
    expect(filter['description'], contains('Written only when it is above 0'));
    expect((properties['version'] as YamlMap)['enum'], [1, 2]);
  });
}
