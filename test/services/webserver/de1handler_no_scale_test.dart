import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

final class _RecordingMockDe1 extends MockDe1 {
  final List<MachineState> requestedStates = [];

  @override
  Future<void> requestState(MachineState newState) async {
    requestedStates.add(newState);
    await super.requestState(newState);
  }
}

void main() {
  late Handler handler;
  late De1Controller controller;
  late _RecordingMockDe1 machine;

  tearDown(() async {
    await controller.dispose();
  });

  Future<void> wire({
    required bool blockOnNoScale,
    required bool scaleConnected,
    required bool cleaningProfile,
    bool machineConnected = true,
  }) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    controller = De1Controller(controller: deviceController);
    machine = _RecordingMockDe1();
    if (machineConnected) {
      controller.adoptDevice(machine);
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );
    }

    final mockSettings = MockSettingsService();
    await mockSettings.setBlockOnNoScale(blockOnNoScale);
    final settingsController = SettingsController(mockSettings);
    await settingsController.loadSettings();

    final scaleController = TestScaleController(TestScale());
    if (!scaleConnected) scaleController.simulateDisconnect();

    final workflowController = WorkflowController();
    if (cleaningProfile) {
      workflowController.updateWorkflow(
        profile: workflowController.currentWorkflow.profile.copyWith(
          beverageType: BeverageType.cleaning,
        ),
      );
    }

    final de1Handler = De1Handler(
      controller: controller,
      settingsController: settingsController,
      scaleController: scaleController,
      workflowController: workflowController,
    );
    final app = Router().plus;
    de1Handler.addRoutes(app);
    handler = app.call;
  }

  Future<Response> requestEspresso() async => await handler(
    Request('PUT', Uri.parse('http://localhost/api/v1/machine/state/espresso')),
  );

  Future<Response> requestState(String name) async => await handler(
    Request('PUT', Uri.parse('http://localhost/api/v1/machine/state/$name')),
  );

  group('PUT /api/v1/machine/state/{newState} — state name', () {
    for (final name in ['brew', 'Espresso', 'notAState']) {
      test(
        'answers 400 for unknown name $name without a machine write',
        () async {
          await wire(
            blockOnNoScale: false,
            scaleConnected: true,
            cleaningProfile: false,
          );
          final res = await requestState(name);
          expect(res.statusCode, 400);
          final body =
              jsonDecode(await res.readAsString()) as Map<String, dynamic>;
          expect(body.keys.toSet().difference({'type', 'details'}), isEmpty);
          expect(body.containsKey('type'), isFalse);
          expect(body['details'], isA<String>());
          expect(body['details'], contains(name));
          expect(machine.requestedStates, isEmpty);
        },
      );
    }

    test('answers 400 for an unknown name before the no-scale block', () async {
      await wire(
        blockOnNoScale: true,
        scaleConnected: false,
        cleaningProfile: false,
      );
      final res = await requestState('brew');
      expect(res.statusCode, 400);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body.containsKey('type'), isFalse);
      expect(machine.requestedStates, isEmpty);
    });

    test('answers 400 for an unknown name with no machine connected', () async {
      await wire(
        blockOnNoScale: false,
        scaleConnected: true,
        cleaningProfile: false,
        machineConnected: false,
      );
      final res = await requestState('brew');
      expect(res.statusCode, 400);
    });

    test('answers 500 for a known name with no machine connected', () async {
      await wire(
        blockOnNoScale: false,
        scaleConnected: true,
        cleaningProfile: false,
        machineConnected: false,
      );
      final res = await requestState('idle');
      expect(res.statusCode, 500);
      expect(machine.requestedStates, isEmpty);
    });

    for (final name in [
      'idle',
      'sleeping',
      'espresso',
      'steam',
      'hotWater',
      'flush',
    ]) {
      test('sends documented name $name to the machine', () async {
        await wire(
          blockOnNoScale: false,
          scaleConnected: true,
          cleaningProfile: false,
        );
        final res = await requestState(name);
        expect(res.statusCode, 200);
        expect(machine.requestedStates, [MachineState.values.byName(name)]);
      });
    }
  });

  group('PUT /api/v1/machine/state/espresso — cleaning profile carve-out', () {
    test('still blocks a normal espresso profile with no scale', () async {
      await wire(
        blockOnNoScale: true,
        scaleConnected: false,
        cleaningProfile: false,
      );
      final res = await requestEspresso();
      expect(res.statusCode, 400);
      final body = jsonDecode(await res.readAsString());
      expect(body['type'], 'block_no_scale');
      expect(machine.requestedStates, isEmpty);
    });

    test(
      'allows a cleaning profile with no scale (no yield to weigh)',
      () async {
        await wire(
          blockOnNoScale: true,
          scaleConnected: false,
          cleaningProfile: true,
        );
        final res = await requestEspresso();
        expect(res.statusCode, 200);
        expect(machine.requestedStates, [MachineState.espresso]);
      },
    );
  });
}
