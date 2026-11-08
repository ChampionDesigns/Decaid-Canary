import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_puck_estimator.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_est_sample.dart';
import 'package:reaprime/src/models/device/impl/difluid/difluid_r2_sensor.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:yaml/yaml.dart';

import '../helpers/mock_device_discovery_service.dart';

const _rest = 'assets/api/rest_v1.yml';
const _ws = 'assets/api/websocket_v1.yml';

YamlMap _schemas(String path) =>
    ((loadYaml(File(path).readAsStringSync()) as YamlMap)['components']
            as YamlMap)['schemas']
        as YamlMap;

class _FakeR2Transport extends BLETransport {
  final BehaviorSubject<ConnectionState> _states = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  void Function(Uint8List)? notify;

  @override
  String get id => 'r2-wire-test';

  @override
  String get name => 'DiFluid R2 000001';

  @override
  TransportType get transportType => TransportType.ble;

  @override
  Stream<ConnectionState> get connectionState => _states.stream;

  @override
  Future<ConnectionState> getConnectionState() async => _states.value;

  @override
  Future<void> connect() async => _states.add(ConnectionState.connected);

  @override
  Future<void> disconnect() async => _states.add(ConnectionState.disconnected);

  @override
  Future<void> dispose() => _states.close();

  @override
  Future<List<String>> discoverServices() async => [
    DifluidR2Sensor.serviceIdentifier.long,
  ];

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async => notify = callback;

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {}

  @override
  Future<void> setTransportPriority(bool prioritized) async {}
}

Uint8List _r2Packet(List<int> data, {int command = 0x00}) {
  final body = [0xDF, 0xDF, 0x03, command, data.length, ...data];
  final sum = body.fold<int>(0, (s, v) => (s + v) & 0xFF);
  return Uint8List.fromList([...body, sum]);
}

ByteData _fullEstimatorFrame() {
  final b = ByteData(23);
  b.setUint8(0, 3);
  b.setUint8(1, 0x05);
  b.setUint16(2, 450, Endian.big);
  b.setUint16(4, 1250, Endian.big);
  b.setUint16(6, 2500, Endian.big);
  b.setUint8(8, 204);
  b.setUint8(9, 15);
  b.setUint8(10, 128);
  b.setUint8(11, 25);
  b.setUint16(12, 130, Endian.big);
  b.setUint16(14, 320, Endian.big);
  b.setUint8(16, 3);
  b.setUint16(17, 88, Endian.big);
  b.setUint8(19, 100);
  b.setUint8(20, 60);
  b.setUint16(21, 1800, Endian.big);
  return b;
}

ByteData _sentinelEstimatorFrame() {
  final b = ByteData(16);
  b.setUint8(0, 1);
  b.setUint16(2, 0xFFFF, Endian.big);
  b.setUint16(4, 0xFFFF, Endian.big);
  b.setUint16(6, 0xFFFF, Endian.big);
  b.setUint8(9, 0xFF);
  b.setUint16(12, 0xFFFF, Endian.big);
  b.setUint16(14, 0xFFFF, Endian.big);
  return b;
}

List<String> _check(
  Object? value,
  YamlMap schema,
  YamlMap schemas, [
  String at = r'$',
]) {
  final ref = schema[r'$ref'];
  if (ref is String) {
    return _check(value, schemas[ref.split('/').last] as YamlMap, schemas, at);
  }
  if (value == null) {
    final type = schema['type'];
    return type == null || type == 'null' || schema['nullable'] == true
        ? const []
        : ['$at is null'];
  }
  final type = schema['type'];
  final typeOk = switch (type) {
    null => true,
    'object' => value is Map,
    'array' => value is List,
    'string' => value is String,
    'number' => value is num,
    'integer' => value is int,
    'boolean' => value is bool,
    _ => false,
  };
  if (!typeOk) return ['$at is ${value.runtimeType}, schema says $type'];

  final errors = <String>[];
  if (value is List && schema['items'] is YamlMap) {
    for (var i = 0; i < value.length; i++) {
      errors.addAll(
        _check(value[i], schema['items'] as YamlMap, schemas, '$at[$i]'),
      );
    }
  }
  if (value is! Map) return errors;

  final required = schema['required'];
  if (required is YamlList) {
    for (final key in required) {
      if (!value.containsKey(key)) errors.add('$at lacks required $key');
    }
  }
  final properties = schema['properties'] is YamlMap
      ? schema['properties'] as YamlMap
      : YamlMap();
  final extra = schema['additionalProperties'];
  for (final entry in value.entries) {
    final property = properties[entry.key];
    final where = '$at.${entry.key}';
    if (property is YamlMap) {
      errors.addAll(_check(entry.value, property, schemas, where));
    } else if (extra == false) {
      errors.add('$where is not allowed');
    } else if (extra is YamlMap) {
      errors.addAll(_check(entry.value, extra, schemas, where));
    }
  }
  return errors;
}

bool _hasManifestType(Object? value, String type) => switch (type) {
  'number' => value is num,
  'integer' => value is int,
  'string' => value is String,
  'boolean' => value is bool,
  'object' => value is Map,
  'array' => value is List,
  _ => false,
};

void main() {
  late SensorController sensorController;
  late HttpServer server;
  late HttpClient client;
  final transports = <_FakeR2Transport>[];

  setUp(() async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    sensorController = SensorController(controller: deviceController);
    final app = Router().plus;
    SensorsHandler(controller: sensorController).addRoutes(app);
    server = await io.serve(app.call, '127.0.0.1', 0);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    sensorController.dispose();
    for (final t in transports) {
      await t.dispose();
    }
    transports.clear();
  });

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<Object?> getJson(String path) async {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok, reason: path);
    return jsonDecode(await response.transform(utf8.decoder).join());
  }

  Future<List<Map<String, dynamic>>> framesFrom(
    Sensor sensor,
    FutureOr<void> Function() produce,
  ) async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse(
        'ws://127.0.0.1:${server.port}/ws/v1/sensors/'
        '${Uri.encodeComponent(sensor.deviceId)}/snapshot',
      ),
    );
    final frames = <Map<String, dynamic>>[];
    final sub = channel.stream.listen(
      (m) => frames.add(jsonDecode(m.toString()) as Map<String, dynamic>),
    );
    await settle();
    await produce();
    await settle();
    await sub.cancel();
    await channel.sink.close();
    return frames;
  }

  Future<Map<String, String>> manifestTypes(Sensor sensor) async {
    final manifest =
        await getJson('/api/v1/sensors/${Uri.encodeComponent(sensor.deviceId)}')
            as Map<String, dynamic>;
    return {
      for (final c in manifest['data'] as List)
        (c as Map)['key'] as String: c['type'] as String,
    };
  }

  void expectFramesMatchSchemas(
    List<Map<String, dynamic>> frames,
    Map<String, String> types,
  ) {
    for (final frame in frames) {
      for (final entry in frame.entries) {
        final type = types[entry.key];
        expect(type, isNotNull, reason: 'undeclared channel ${entry.key}');
        if (entry.value != null) {
          expect(
            _hasManifestType(entry.value, type!),
            isTrue,
            reason: '${entry.key}=${entry.value} is not $type',
          );
        }
      }
      for (final path in [_rest, _ws]) {
        final schemas = _schemas(path);
        expect(
          _check(frame, schemas['SensorSnapshot'] as YamlMap, schemas),
          isEmpty,
          reason: '$path SensorSnapshot rejects $frame',
        );
      }
    }
  }

  Future<BenglePuckEstimator> puckEstimator(MockBengle bengle) async {
    final sensor = BenglePuckEstimator(bengle: bengle);
    await sensorController.register(sensor);
    return sensor;
  }

  Future<(DifluidR2Sensor, _FakeR2Transport)> difluid() async {
    final transport = _FakeR2Transport();
    transports.add(transport);
    final sensor = DifluidR2Sensor(transport: transport);
    await sensorController.register(sensor);
    return (sensor, transport);
  }

  group('SensorSnapshot matches the frames the app sends', () {
    test('puck-estimator frames, full and with unobserved channels', () async {
      final bengle = MockBengle(deviceId: 'DE1-1234');
      final sensor = await puckEstimator(bengle);
      final frames = await framesFrom(sensor, () {
        bengle.emitPuckEstimator(parseBengleEstSample(_fullEstimatorFrame())!);
        bengle.emitPuckEstimator(
          parseBengleEstSample(_sentinelEstimatorFrame())!,
        );
      });

      expect(frames, hasLength(2));
      expect(frames.first.keys, hasLength(17));
      expect(frames.first['timestamp'], isA<String>());
      expect(frames.last, isNot(contains('r1')));
      expectFramesMatchSchemas(frames, await manifestTypes(sensor));
    });

    test(
      'DiFluid R2 status, null measuring, reading and error frames',
      () async {
        final (sensor, transport) = await difluid();
        final frames = await framesFrom(sensor, () async {
          transport.notify!(_r2Packet([0x00, 4]));
          await settle();
          transport.notify!(_r2Packet([0x00, 7]));
          await settle();
          transport.notify!(_r2Packet([0x02, 0x03, 0xCA]));
          await settle();
          transport.notify!(_r2Packet([0x02, 0x03], command: 0xFE));
        });

        expect(frames, hasLength(4));
        expect(frames[0]['status'], 'average_started');
        expect(frames[0]['measuring'], isTrue);
        expect(frames[1], containsPair('measuring', null));
        expect(frames[2]['tds'], closeTo(9.7, 1e-9));
        expect(frames[3], containsPair('error', 'no_liquid'));
        expectFramesMatchSchemas(frames, await manifestTypes(sensor));
      },
    );

    for (final path in [_rest, _ws]) {
      test('$path SensorSnapshot has no values or id wrapper', () {
        final schema = _schemas(path)['SensorSnapshot'] as YamlMap;
        expect(schema['type'], 'object');
        expect(schema['required'], isNull);
        expect(schema['properties'], isNull);
        expect(schema['additionalProperties'], isNotNull);
        expect(schema['additionalProperties'], isNot(false));
      });
    }
  });
}
