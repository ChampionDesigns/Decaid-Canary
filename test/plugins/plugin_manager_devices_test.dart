import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

void main() {
  test(
    'declared plugin sensor connects, publishes, and executes commands',
    () async {
      final deviceService = PluginDeviceService();
      final deviceController = DeviceController([deviceService]);
      await deviceController.initialize();
      final sensorController = SensorController(controller: deviceController);
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: deviceService,
      );
      addTearDown(() async {
        await manager.dispose();
        sensorController.dispose();
        deviceController.dispose();
      });

      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .map((event) => event['payload'] as String)
          .first;
      await manager.loadPlugin(
        id: 'humidity.plugin',
        manifest: testManifest(
          'humidity.plugin',
          permissions: const {PluginPermissions.emit},
          drivers: const [
            PluginDriverDeclaration(
              id: 'humidity',
              type: PluginDriverType.sensor,
            ),
          ],
        ),
        settings: const {},
        jsCode: '''
        function createPlugin(host) {
          return {
            id: "humidity.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [
                  { key: "relativeHumidity", type: "number", unit: "%RH" }
                ],
                commands: [{ id: "sampleNow" }, { id: "wait" }]
              }, {
                connect() {},
                disconnect() {
                  globalThis.disconnectCalls = (globalThis.disconnectCalls || 0) + 1;
                },
                execute(command) {
                  if (command.commandId === "wait") return new Promise(() => {});
                  return { relativeHumidity: 53.1, commandId: command.commandId };
                }
              }).then((device) => {
                globalThis.testHumidityDevice = device;
                host.emit("registered", device.deviceId);
              });
            },
            onUnload() {
              throw new Error("unload failed");
            }
          };
        }
      ''',
      );

      final deviceId = await registered.timeout(const Duration(seconds: 2));
      expect(deviceId, 'plugin:humidity.plugin:humidity:office');
      final sensor = await sensorController.sensorRegistry
          .map((sensors) => sensors[deviceId])
          .where((sensor) => sensor != null)
          .cast<Sensor>()
          .first;
      await sensor.connectionState
          .where((state) => state == ConnectionState.connected)
          .first;

      expect(await sensor.execute('sampleNow', null), {
        'relativeHumidity': 53.1,
        'commandId': 'sampleNow',
      });
      final snapshot = sensor.data.first;
      manager.js.evaluate(
        'globalThis.testHumidityDevice.publish({ relativeHumidity: 52.4 });',
      );
      expect(await snapshot.timeout(const Duration(seconds: 2)), {
        'relativeHumidity': 52.4,
      });

      final pendingCommand = expectLater(
        sensor.execute('wait', null),
        throwsA(
          isA<PluginDeviceException>().having(
            (error) => error.message,
            'message',
            contains('unloaded'),
          ),
        ),
      );
      await manager.unloadPlugin('humidity.plugin');
      await pendingCommand;
      await sensorController.sensorRegistry
          .where((sensors) => !sensors.containsKey(deviceId))
          .first;
      expect(deviceController.devices, isEmpty);
      // Unload runs the disconnect handler exactly once even though onUnload
      // threw, then removes the device.
      expect(
        manager.js.evaluate('globalThis.disconnectCalls').stringResult,
        '1',
      );
    },
  );

  test('undeclared driver registration is rejected', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    final error = manager.emitStream
        .where((event) => event['event'] == 'result')
        .map((event) => event['payload'] as String)
        .first;

    await manager.loadPlugin(
      id: 'undeclared.plugin',
      manifest: testManifest(
        'undeclared.plugin',
        permissions: const {PluginPermissions.emit},
      ),
      settings: const {},
      jsCode: '''
        function createPlugin(host) {
          return {
            id: "undeclared.plugin",
            onLoad() {
              __deviceSetHandlers("direct_registration", {
                pluginId: "undeclared.plugin",
                generation: pluginGeneration,
                bridgeToken: pluginBridgeToken,
                handlers: { connect() {}, disconnect() {}, execute() {} }
              });
              __deviceRegisterPending("direct_request", {
                bridgeToken: pluginBridgeToken,
                resolve: () => host.emit("result", "unexpected"),
                reject: (error) => host.emit("result", error.message)
              });
              pluginHostBridge.deviceRequest(
                pluginBridgeToken,
                pluginGeneration,
                "direct_request",
                "register",
                {
                  registrationHandle: "direct_registration",
                  definition: {
                    driverId: "humidity",
                    instanceId: "office",
                    name: "Office humidity",
                    vendor: "Test",
                    dataChannels: [{ key: "relativeHumidity", type: "number" }]
                  }
                }
              );
            }
          };
        }
      ''',
    );

    expect(
      await error.timeout(const Duration(seconds: 2)),
      contains('not declared'),
    );
    expect(await manager.deviceService.devices.first, isEmpty);
  });

  test('device command times out', () async {
    final deviceService = PluginDeviceService();
    final deviceController = DeviceController([deviceService]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: deviceService,
      deviceInvocationTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(() async {
      await manager.dispose();
      sensorController.dispose();
      deviceController.dispose();
    });

    final registered = manager.emitStream
        .where((event) => event['event'] == 'registered')
        .map((event) => event['payload'] as String)
        .first;
    await manager.loadPlugin(
      id: 'timeout.plugin',
      manifest: testManifest(
        'timeout.plugin',
        permissions: const {PluginPermissions.emit},
        drivers: const [
          PluginDriverDeclaration(
            id: 'humidity',
            type: PluginDriverType.sensor,
          ),
        ],
      ),
      settings: const {},
      jsCode: '''
        function createPlugin(host) {
          return {
            id: "timeout.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }],
                commands: [{ id: "sampleNow" }]
              }, {
                connect() {},
                disconnect() {},
                execute() { return new Promise(() => {}); }
              }).then((device) => host.emit("registered", device.deviceId));
            }
          };
        }
      ''',
    );
    final deviceId = await registered.timeout(const Duration(seconds: 2));
    final sensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[deviceId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    await sensor.connectionState
        .where((state) => state == ConnectionState.connected)
        .first;

    await expectLater(
      sensor.execute('sampleNow', null),
      throwsA(
        isA<PluginDeviceException>().having(
          (error) => error.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
  });

  test(
    'direct device.unregister calls disconnect once and removes device',
    () async {
      final deviceService = PluginDeviceService();
      final deviceController = DeviceController([deviceService]);
      await deviceController.initialize();
      final sensorController = SensorController(controller: deviceController);
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: deviceService,
      );
      addTearDown(() async {
        await manager.dispose();
        sensorController.dispose();
        deviceController.dispose();
      });

      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .map((event) => event['payload'] as String)
          .first;
      await manager.loadPlugin(
        id: 'unregister.plugin',
        manifest: testManifest(
          'unregister.plugin',
          permissions: const {PluginPermissions.emit},
          drivers: const [
            PluginDriverDeclaration(
              id: 'humidity',
              type: PluginDriverType.sensor,
            ),
          ],
        ),
        settings: const {},
        jsCode: '''
        function createPlugin(host) {
          return {
            id: "unregister.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect() {},
                disconnect() {
                  globalThis.disconnectCalls = (globalThis.disconnectCalls || 0) + 1;
                },
                execute() { return {}; }
              }).then((device) => {
                globalThis.testUnregisterDevice = device;
                globalThis.performUnregister = () => device.unregister().then(() => {
                  host.emit("unregistered", device.deviceId);
                });
                host.emit("registered", device.deviceId);
              });
            }
          };
        }
      ''',
      );

      final deviceId = await registered.timeout(const Duration(seconds: 2));
      final sensor = await sensorController.sensorRegistry
          .map((sensors) => sensors[deviceId])
          .where((sensor) => sensor != null)
          .cast<Sensor>()
          .first;
      await sensor.connectionState
          .where((state) => state == ConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 2));

      final unregistered = manager.emitStream
          .where((event) => event['event'] == 'unregistered')
          .map((event) => event['payload'] as String)
          .first;
      manager.js.evaluate('globalThis.performUnregister();');
      expect(await unregistered.timeout(const Duration(seconds: 2)), deviceId);
      expect(
        manager.js
            .evaluate('String(globalThis.disconnectCalls || 0)')
            .stringResult,
        '1',
      );
      await sensorController.sensorRegistry
          .where((sensors) => !sensors.containsKey(deviceId))
          .first;
      expect(deviceController.devices, isEmpty);
    },
  );

  test('unregister removes the device even when disconnect fails', () async {
    final deviceService = PluginDeviceService();
    final deviceController = DeviceController([deviceService]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: deviceService,
    );
    addTearDown(() async {
      await manager.dispose();
      sensorController.dispose();
      deviceController.dispose();
    });

    final registered = manager.emitStream
        .where((event) => event['event'] == 'registered')
        .map((event) => event['payload'] as String)
        .first;
    await manager.loadPlugin(
      id: 'unregister-failure.plugin',
      manifest: testManifest(
        'unregister-failure.plugin',
        permissions: const {PluginPermissions.emit},
        drivers: const [
          PluginDriverDeclaration(
            id: 'humidity',
            type: PluginDriverType.sensor,
          ),
        ],
      ),
      settings: const {},
      jsCode: '''
        function createPlugin(host) {
          return {
            id: "unregister-failure.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect() {},
                disconnect() {
                  globalThis.disconnectCalls = (globalThis.disconnectCalls || 0) + 1;
                  throw new Error("transport busy");
                },
                execute() { return {}; }
              }).then((device) => {
                globalThis.performFailingUnregister = () => device.unregister().then(
                  () => host.emit("unregistered", "unexpected success"),
                  (error) => host.emit("unregistered-failed", String(error))
                );
                host.emit("registered", device.deviceId);
              });
            }
          };
        }
      ''',
    );

    final deviceId = await registered.timeout(const Duration(seconds: 2));
    final sensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[deviceId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    await sensor.connectionState
        .where((state) => state == ConnectionState.connected)
        .first
        .timeout(const Duration(seconds: 2));

    final failure = manager.emitStream
        .where((event) => event['event'] == 'unregistered-failed')
        .map((event) => event['payload'] as String)
        .first;
    manager.js.evaluate('globalThis.performFailingUnregister();');
    expect(
      await failure.timeout(const Duration(seconds: 2)),
      contains('transport busy'),
    );
    expect(
      manager.js
          .evaluate('String(globalThis.disconnectCalls || 0)')
          .stringResult,
      '1',
    );
    // The disconnect failure does not leave a half-registered device behind.
    await sensorController.sensorRegistry
        .where((sensors) => !sensors.containsKey(deviceId))
        .first;
    expect(deviceController.devices, isEmpty);
  });
}
