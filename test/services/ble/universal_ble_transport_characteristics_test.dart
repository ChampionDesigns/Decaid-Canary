import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/services/ble/universal_ble_transport.dart';
import 'package:universal_ble/universal_ble.dart';

class _GattBlePlatform extends UniversalBlePlatform {
  _GattBlePlatform(this.services);

  final List<BleService> services;
  final List<(String, String)> notifiable = [];
  bool attached = false;

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => expectedMtu;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      AvailabilityState.poweredOn;

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> disableBluetooth() async => false;

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> isScanning() async => false;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    attached = true;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    attached = false;
    updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async {
    if (!attached) throw StateError('Peripheral is not attached');
    return services;
  }

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    notifiable.add((service, characteristic));
  }

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {}

  @override
  Future<int> readRssi(String deviceId) async => -50;

  @override
  Future<void> requestConnectionPriority(
    String deviceId,
    BleConnectionPriority priority,
  ) async {}

  @override
  Future<bool> isPaired(String deviceId) async => false;

  @override
  Future<bool> pair(String deviceId) async => true;

  @override
  Future<void> unpair(String deviceId) async {}

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      attached ? BleConnectionState.connected : BleConnectionState.disconnected;

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      [];
}

const _estimatorLong = '0000a014-0000-1000-8000-00805f9b34fb';
const _serviceLong = '0000a000-0000-1000-8000-00805f9b34fb';

Future<(UniversalBleTransport, _GattBlePlatform)> _connectedTransport({
  required List<BleService> services,
  required bool linux,
  required String deviceId,
}) async {
  final platform = _GattBlePlatform(services);
  UniversalBle.setInstance(platform);
  UniversalBle.clearQueue();
  final transport = UniversalBleTransport(
    device: BleDevice(deviceId: deviceId, name: 'Bengle'),
    isAndroidOverride: false,
    isLinuxOverride: linux,
  );
  await transport.connect();
  await transport.discoverServices();
  return (transport, platform);
}

void main() {
  for (final linux in [false, true]) {
    group('UniversalBleTransport characteristics (linux=$linux)', () {
      test(
        'finds short-form characteristics by short or long service UUID',
        () async {
          final (transport, platform) = await _connectedTransport(
            services: [
              BleService('A000', [
                BleCharacteristic('A014', const [], const []),
              ]),
            ],
            linux: linux,
            deviceId: 'AA:BB:CC:DD:EE:${linux ? '11' : '10'}',
          );

          expect(await transport.discoverCharacteristics('A000'), [
            _estimatorLong,
          ]);
          expect(await transport.discoverCharacteristics(_serviceLong), [
            _estimatorLong,
          ]);
          await transport.dispose();
        },
      );

      test(
        'subscribeEstimator subscribes when the machine has 0xA014',
        () async {
          final (transport, platform) = await _connectedTransport(
            services: [
              BleService(_serviceLong.toUpperCase(), [
                BleCharacteristic(
                  _estimatorLong.toUpperCase(),
                  const [],
                  const [],
                ),
              ]),
            ],
            linux: linux,
            deviceId: 'AA:BB:CC:DD:EE:${linux ? '21' : '20'}',
          );
          final de1 = UnifiedDe1Transport(transport: transport);

          expect(await de1.subscribeEstimator(), isTrue);
          expect(
            platform.notifiable.map((n) => n.$2.toLowerCase()),
            contains(_estimatorLong),
          );
          await transport.dispose();
        },
      );

      test('subscribeEstimator skips when the machine lacks 0xA014', () async {
        final (transport, platform) = await _connectedTransport(
          services: [
            BleService('A000', [BleCharacteristic('A00E', const [], const [])]),
          ],
          linux: linux,
          deviceId: 'AA:BB:CC:DD:EE:${linux ? '31' : '30'}',
        );
        final de1 = UnifiedDe1Transport(transport: transport);

        expect(await de1.subscribeEstimator(), isFalse);
        expect(
          platform.notifiable.map((n) => n.$2.toLowerCase()),
          isNot(contains(_estimatorLong)),
        );
        await transport.dispose();
      });
    });
  }
}
