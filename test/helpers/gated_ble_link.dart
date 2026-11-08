import 'dart:async';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/ble/ble_admission_transport.dart';

import 'fake_ble_transport.dart';

class GatedBleLink extends FakeBleTransport {
  int timeoutsLeft = 1;
  bool linked = false;
  bool disposed = false;
  int confirmedDisconnectCalls = 0;
  Completer<void>? teardownGate;
  Completer<void>? connectGate;
  Completer<void>? timeoutGate;
  Object? connectError;
  final subscribeGates = <String, Completer<void>>{};
  final subscribeCounts = <String, int>{};
  int gattCalls = 0;
  Future<void> _lifecycle = Future.value();

  Future<void> _serial(Future<void> Function() step) {
    final next = _lifecycle.then((_) => step());
    _lifecycle = next.then((_) {}, onError: (_) {});
    return next;
  }

  void _emit(ConnectionState state) {
    if (!disposed) emitConnectionState(state);
  }

  Future<void> _teardown() async {
    final gate = teardownGate;
    teardownGate = null;
    await gate?.future;
    linked = false;
    subscribers.clear();
    _emit(ConnectionState.disconnected);
  }

  @override
  Future<void> connect() => _serial(() async {
    await super.connect();
    final gate = connectGate;
    connectGate = null;
    await gate?.future;
    final error = connectError;
    connectError = null;
    if (error != null) throw error;
    linked = true;
    _emit(ConnectionState.connected);
  });

  @override
  Future<void> disconnect() => _serial(() async {
    await super.disconnect();
    await _teardown();
  });

  @override
  Future<void> disconnectConfirmed() => _serial(() async {
    confirmedDisconnectCalls++;
    await _teardown();
  });

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    gattCalls++;
    subscribeCounts.update(characteristicUUID, (n) => n + 1, ifAbsent: () => 1);
    await super.subscribe(serviceUUID, characteristicUUID, callback);
    await subscribeGates.remove(characteristicUUID)?.future;
  }

  @override
  Future<List<String>> discoverServices() {
    gattCalls++;
    return super.discoverServices();
  }

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) {
    gattCalls++;
    return super.read(serviceUUID, characteristicUUID, timeout: timeout);
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (characteristicUUID == Endpoint.requestedState.uuid &&
        timeoutsLeft > 0) {
      timeoutsLeft--;
      final gate = timeoutGate;
      timeoutGate = null;
      await gate?.future;
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

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

enum BleLinkPath { raw, admission }

DataTransport overBleLink(BleLinkPath path, GatedBleLink link) =>
    switch (path) {
      BleLinkPath.raw => link,
      BleLinkPath.admission => BleAdmissionTransport(
        transport: link,
        reserve: Object.new,
        release: (_) {},
      ),
    };

int requestedStateWrites(FakeBleTransport t) => t.writes
    .where((w) => w.characteristicUUID == Endpoint.requestedState.uuid)
    .length;

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
