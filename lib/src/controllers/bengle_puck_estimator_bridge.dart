import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_puck_estimator.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_est_sample.dart';

/// Registers [BenglePuckEstimator] with the [SensorController] once the
/// machine actually produces estimator data.
///
/// Registration is driven by the first decoded frame rather than by connection,
/// because not every machine emits `0xA014`. A firmware without the observer,
/// a BLE-connected Bengle whose firmware does not register the characteristic,
/// or a plain DE1 never emits it, and none of them should advertise an
/// estimator sensor that would only ever report nothing.
class BenglePuckEstimatorBridge {
  BenglePuckEstimatorBridge({
    required De1Controller de1Controller,
    required SensorController sensorController,
  }) : _de1 = de1Controller,
       _sensors = sensorController {
    _de1Sub = _de1.de1.listen(_enqueueMachineChange);
  }

  final De1Controller _de1;
  final SensorController _sensors;
  final Logger _log = Logger('BenglePuckEstimatorBridge');

  StreamSubscription<De1Interface?>? _de1Sub;
  StreamSubscription<BengleEstSample>? _sampleSub;
  StreamSubscription<bool>? _availableSub;
  BenglePuckEstimator? _registered;
  BengleInterface? _attachedBengle;
  bool _restoreWhenAvailable = false;
  Future<void> _machineChanges = Future<void>.value();

  void _enqueueMachineChange(De1Interface? device) =>
      _enqueue(() => _onMachineChange(device));

  void _enqueue(Future<void> Function() change) {
    _machineChanges = _machineChanges
        .then((_) => change())
        .catchError(
          (Object e, StackTrace st) =>
              _log.warning('machine change handling failed', e, st),
        );
  }

  Future<void> _onMachineChange(De1Interface? device) async {
    if (device is BengleInterface) {
      if (identical(_attachedBengle, device)) return;
      await _detachCurrent();
      _attachedBengle = device;
      _sampleSub = device.puckEstimator.listen(_onSample);
      _availableSub = device.puckEstimatorAvailable.listen(
        (available) => _enqueue(() => _onAvailability(device, available)),
      );
    } else {
      await _detachCurrent();
    }
  }

  Future<void> _onSample(BengleEstSample _) async {
    final bengle = _attachedBengle;
    if (bengle == null || _registered != null) return;
    _log.info('Bengle puck estimator producing data — registering sensor');
    await _register(bengle);
  }

  Future<void> _onAvailability(BengleInterface bengle, bool available) async {
    if (!identical(_attachedBengle, bengle)) return;
    if (available) {
      if (!_restoreWhenAvailable) return;
      _restoreWhenAvailable = false;
      if (_registered != null) return;
      _log.info('Bengle puck estimator available again — registering sensor');
      await _register(bengle);
      return;
    }
    final sensor = _registered;
    if (sensor == null) return;
    _registered = null;
    _restoreWhenAvailable = true;
    _log.info('Bengle puck estimator lost — unregistering sensor');
    await _sensors.unregister(sensor.deviceId);
  }

  Future<void> _register(BengleInterface bengle) async {
    final sensor = BenglePuckEstimator(bengle: bengle);
    _registered = sensor;
    await _sensors.register(sensor);
  }

  Future<void> _detachCurrent() async {
    await _sampleSub?.cancel();
    _sampleSub = null;
    await _availableSub?.cancel();
    _availableSub = null;
    _restoreWhenAvailable = false;
    final sensor = _registered;
    if (sensor != null) {
      _registered = null;
      await _sensors.unregister(sensor.deviceId);
    }
    _attachedBengle = null;
  }

  Future<void> dispose() async {
    await _de1Sub?.cancel();
    _de1Sub = null;
    await _machineChanges;
    await _detachCurrent();
  }
}
