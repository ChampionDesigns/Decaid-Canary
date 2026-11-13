import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:yaml/yaml.dart';

List<String> _machineStates(String specPath) {
  final spec = loadYaml(File(specPath).readAsStringSync()) as YamlMap;
  final schemas = (spec['components'] as YamlMap)['schemas'] as YamlMap;
  final values = (schemas['MachineState'] as YamlMap)['enum'] as YamlList;
  return values.map((value) => value.toString()).toList();
}

void main() {
  group('MachineState spec contract', () {
    final dartNames = MachineState.values.map((e) => e.name).toList();

    test('rest_v1.yml MachineState equals the Dart enum', () {
      expect(_machineStates('assets/api/rest_v1.yml'), dartNames);
    });

    test('websocket_v1.yml MachineState equals the Dart enum', () {
      expect(_machineStates('assets/api/websocket_v1.yml'), dartNames);
    });
  });
}
