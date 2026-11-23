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
}
