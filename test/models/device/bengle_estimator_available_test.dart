import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/bengle_puck_estimator_bridge.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_est_sample.dart'
    show bengleEstSampleBytes, parseBengleEstSample;
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:rxdart/rxdart.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/mock_device_discovery_service.dart';

class _TimeoutOnceTransport extends FakeBleTransport {
  bool timeoutNextWrite = false;
  bool failEstimatorSubscribe = false;

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    if (failEstimatorSubscribe &&
        characteristicUUID == Endpoint.estimator.uuid) {
      throw StateError('estimator subscribe failed');
    }
    await super.subscribe(serviceUUID, characteristicUUID, callback);
  }

  @override
  Future<void> disconnect() async {
    await super.disconnect();
    subscribers.clear();
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (timeoutNextWrite) {
      timeoutNextWrite = false;
      throw BleTimeoutException('write');
    }
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }
}

class _SwitchableBengle extends MockBengle {
  _SwitchableBengle() : super(deviceId: 'BengleSwitch');

  final BehaviorSubject<bool> available = BehaviorSubject.seeded(true);

  @override
  Stream<bool> get puckEstimatorAvailable => available.stream;
}

class _StubDe1Controller extends De1Controller {
  _StubDe1Controller(DeviceController devices)
    : _subject = BehaviorSubject.seeded(null),
      super(controller: devices);

  final BehaviorSubject<De1Interface?> _subject;

  @override
  Stream<De1Interface?> get de1 => _subject.stream;

  void emit(De1Interface? device) => _subject.add(device);
}

class _CountingSensorController extends SensorController {
  _CountingSensorController({required super.controller});

  int unregisters = 0;

  @override
  Future<void> unregister(String deviceId) {
    unregisters++;
    return super.unregister(deviceId);
  }
}

List<int> _frame(int r1Raw) {
  final b = ByteData(bengleEstSampleBytes);
  b.setUint8(0, 1);
  b.setUint16(2, r1Raw, Endian.big);
  return b.buffer.asUint8List();
}

_TimeoutOnceTransport _transport({required bool hasEstimator}) =>
    _TimeoutOnceTransport()
      ..presentCharacteristics = [if (hasEstimator) Endpoint.estimator.uuid]
      ..queueOnConnectResponses(v13Model: 128, calFlowEst: 100)
      ..queuePaletteHydrationResponses();

Future<void> settle() => pumpEventQueue();

// ignore: invalid_use_of_protected_member
Future<bool> _subscribeEstimator(Bengle bengle) => bengle.enableEstimator();

void main() {
  late DeviceController devices;
  late _CountingSensorController sensors;
  late _StubDe1Controller de1Controller;
  late BenglePuckEstimatorBridge bridge;

  setUp(() async {
    devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    sensors = _CountingSensorController(controller: devices);
    de1Controller = _StubDe1Controller(devices);
    bridge = BenglePuckEstimatorBridge(
      de1Controller: de1Controller,
      sensorController: sensors,
    );
  });

  tearDown(() async {
    await bridge.dispose();
    sensors.dispose();
  });

  Sensor? estimator() => sensors.sensors.values
      .where((s) => s.deviceId.endsWith('-puckestimator'))
      .firstOrNull;

  Future<Bengle> connectedBengle(_TimeoutOnceTransport t) async {
    final bengle = Bengle(transport: t);
    addTearDown(bengle.dispose);
    await bengle.onConnect();
    return bengle;
  }

  test('a normal connect with A014 reports available once and never '
      'unregisters', () async {
    final t = _transport(hasEstimator: true);
    final bengle = Bengle(transport: t);
    addTearDown(bengle.dispose);
    final seen = <bool>[];
    final sub = bengle.puckEstimatorAvailable.listen(seen.add);
    addTearDown(sub.cancel);

    await bengle.onConnect();
    de1Controller.emit(bengle);
    await settle();
    t.emitNotification(Endpoint.estimator, _frame(450));
    await settle();

    expect(seen, [true]);
    expect(estimator(), isNotNull);
    expect(sensors.unregisters, 0);
  });

  test('a connect without A014 reports unavailable and registers '
      'nothing', () async {
    final bengle = await connectedBengle(_transport(hasEstimator: false));
    de1Controller.emit(bengle);
    await settle();

    expect(await bengle.puckEstimatorAvailable.first, isFalse);
    expect(estimator(), isNull);
    expect(sensors.unregisters, 0);
  });

  test('a recovery that loses A014 unregisters the sensor, and a later good '
      'subscribe registers it again with frames', () async {
    final t = _transport(hasEstimator: true);
    final bengle = await connectedBengle(t);
    final seen = <bool>[];
    final sub = bengle.puckEstimatorAvailable.listen(seen.add);
    addTearDown(sub.cancel);
    de1Controller.emit(bengle);
    await settle();
    t.emitNotification(Endpoint.estimator, _frame(450));
    await settle();
    expect(estimator(), isNotNull);

    t.presentCharacteristics = const [];
    t.timeoutNextWrite = true;
    await bengle.requestState(MachineState.idle);
    await settle();

    expect(seen, [true, false]);
    expect(estimator(), isNull);
    expect(sensors.unregisters, 1);

    t.presentCharacteristics = [Endpoint.estimator.uuid];
    expect(await _subscribeEstimator(bengle), isTrue);
    await settle();

    expect(seen, [true, false, true]);
    final restored = estimator();
    expect(restored, isNotNull);
    final frames = <Map<String, dynamic>>[];
    final dataSub = restored!.data.listen(frames.add);
    addTearDown(dataSub.cancel);
    await settle();
    expect(frames, isEmpty);

    t.emitNotification(Endpoint.estimator, _frame(320));
    await settle();

    expect(frames, hasLength(1));
    expect(frames.single['r1'], closeTo(3.2, 1e-9));
  });

  test('a recovery that keeps A014 leaves the sensor registered', () async {
    final t = _transport(hasEstimator: true);
    final bengle = await connectedBengle(t);
    de1Controller.emit(bengle);
    await settle();
    t.emitNotification(Endpoint.estimator, _frame(450));
    await settle();
    final before = estimator();

    t.timeoutNextWrite = true;
    await bengle.requestState(MachineState.idle);
    await settle();

    expect(identical(estimator(), before), isTrue);
    expect(sensors.unregisters, 0);
  });

  test('an unavailable machine that never sent a frame gets no sensor when '
      'A014 comes back', () async {
    final t = _transport(hasEstimator: false);
    final bengle = await connectedBengle(t);
    de1Controller.emit(bengle);
    await settle();

    t.presentCharacteristics = [Endpoint.estimator.uuid];
    expect(await _subscribeEstimator(bengle), isTrue);
    await settle();

    expect(estimator(), isNull);
  });

  test('a recovery whose estimator subscribe throws reports unavailable and '
      'unregisters the sensor', () async {
    final t = _transport(hasEstimator: true);
    final bengle = await connectedBengle(t);
    final seen = <bool>[];
    final sub = bengle.puckEstimatorAvailable.listen(seen.add);
    addTearDown(sub.cancel);
    de1Controller.emit(bengle);
    await settle();
    t.emitNotification(Endpoint.estimator, _frame(450));
    await settle();
    expect(estimator(), isNotNull);

    t.failEstimatorSubscribe = true;
    t.timeoutNextWrite = true;
    await bengle
        .requestState(MachineState.idle)
        .then<void>((_) {}, onError: (Object _) {});
    await settle();

    expect(seen, [true, false]);
    expect(estimator(), isNull);
    expect(sensors.unregisters, 1);
  });

  for (final lateFrameFirst in [true, false]) {
    test('a frame that arrives ${lateFrameFirst ? 'before' : 'after'} the '
        'loss is handled does not register a sensor on a lost '
        'estimator', () async {
      final bengle = _SwitchableBengle();
      addTearDown(bengle.available.close);
      final sample = parseBengleEstSample(
        ByteData.sublistView(Uint8List.fromList(_frame(450))),
      )!;
      de1Controller.emit(bengle);
      await settle();
      bengle.emitPuckEstimator(sample);
      await settle();
      expect(estimator(), isNotNull);

      bengle.available.add(false);
      if (!lateFrameFirst) await settle();
      bengle.emitPuckEstimator(sample);
      await settle();

      expect(estimator(), isNull);

      bengle.available.add(true);
      await settle();

      expect(estimator(), isNotNull);
      expect(sensors.unregisters, 1);
    });
  }
}
