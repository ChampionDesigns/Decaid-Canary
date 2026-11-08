import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

/// POST /api/v1/machine/profile is the machine-push choke point for the
/// capability refusal gate. A profile with a Power/Lever step must land as a
/// CLEAN 400 (with the refusal message) when the machine has not advertised the
/// matching caps bit — not the opaque 500 the withDe1 catch-all would otherwise
/// produce — and go through (200) when it has.
class _BengleBackedDe1 extends MockDe1 {
  _BengleBackedDe1(this.bengle);

  final Bengle bengle;
  int setProfileCalls = 0;

  @override
  Future<void> setProfile(Profile profile) async {
    setProfileCalls++;
    await bengle.setProfile(profile);
  }
}

void main() {
  late Handler handler;
  late De1Controller controller;

  Future<void> wireWith(De1Interface device) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    addTearDown(deviceController.dispose);
    controller = De1Controller(controller: deviceController);
    addTearDown(controller.dispose);
    await controller.connectToDe1(device);
    await controller.initSettled.firstWhere((generation) => generation != null);

    final mockSettings = MockSettingsService();
    final settingsController = SettingsController(mockSettings);
    await settingsController.loadSettings();

    final scaleController = TestScaleController(TestScale());

    final de1Handler = De1Handler(
      controller: controller,
      settingsController: settingsController,
      scaleController: scaleController,
      workflowController: WorkflowController(),
    );
    final app = Router().plus;
    de1Handler.addRoutes(app);
    handler = app.call;
  }

  /// Connect a real Bengle over the fake transport, advertising [caps].
  Future<Bengle> connectedBengle(int caps) async {
    final transport = FakeBleTransport();
    final bengle = Bengle(transport: transport);
    transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
    transport.queueOnConnectResponses(v13Model: 128, profileModeCaps: caps);
    // Bengle.onConnect also hydrates the LED palette. Without a queued answer
    // that read waits out its fail-closed timeout - 12.6 s per test, and this
    // file was the slowest in the whole suite because of it.
    transport.queuePaletteHydrationResponses();
    await bengle.onConnect();
    addTearDown(transport.dispose);
    return bengle;
  }

  Future<_BengleBackedDe1> bengleMachine(int caps) async =>
      _BengleBackedDe1(await connectedBengle(caps));

  Future<Response> postProfile(Map<String, dynamic> profile) async => handler(
    Request(
      'POST',
      Uri.parse('http://localhost/api/v1/machine/profile'),
      body: jsonEncode(profile),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    ),
  );

  Map<String, dynamic> leverProfile() => {
    'version': '2',
    'title': 'Lever demo',
    'beverage_type': 'espresso',
    'steps': <dynamic>[
      {
        'name': 'lever',
        'pump': 'lever',
        'transition': 'smooth',
        'volume': 100,
        'seconds': 40,
        'temperature': 92,
        'sensor': 'coffee',
        'pressure': 9.0,
        'leverSpring': 0.9,
        'leverGive': 1.5,
      },
    ],
    'tank_temperature': 90.0,
    'target_weight': 36.0,
    'target_volume_count_start': 0,
  };

  Map<String, dynamic> powerProfileNoLimiter() => {
    'version': '2',
    'title': 'Power (bad)',
    'beverage_type': 'espresso',
    'steps': <dynamic>[
      {
        'name': 'power',
        'pump': 'power',
        'transition': 'smooth',
        'volume': 100,
        'seconds': 25,
        'temperature': 93,
        'sensor': 'coffee',
        'power': 2.0,
      },
    ],
    'tank_temperature': 90.0,
    'target_volume_count_start': 0,
  };

  group('POST /api/v1/machine/profile — capability refusal gate', () {
    test(
      '400 (not 500) with the refusal message when caps are absent',
      () async {
        await wireWith(await bengleMachine(0));

        final res = await postProfile(leverProfile());

        expect(res.statusCode, 400);
        final body =
            jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        expect(body['error'], 'Unsupported profile');
        expect(body['message'], contains('Lever'));
        expect(body['message'], contains('does not support'));
      },
    );

    test(
      '200 when the machine advertises the Lever capability (0x3)',
      () async {
        await wireWith(await bengleMachine(0x3));

        final res = await postProfile(leverProfile());

        expect(res.statusCode, 200);
      },
    );

    test(
      '400 for a power step missing its mandatory limiter (FormatException)',
      () async {
        await wireWith(await bengleMachine(0x3));

        final res = await postProfile(powerProfileNoLimiter());

        expect(res.statusCode, 400);
        final body =
            jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        expect(body['error'], 'Invalid profile');
      },
    );

    test('the profile upload waits behind a queued device write', () async {
      final machine = await bengleMachine(0x3);
      await wireWith(machine);
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final started = Completer<void>();
      final held = controller.runDeviceWrite((_) async {
        started.complete();
        await release.future;
      });
      await started.future;

      final pending = postProfile(leverProfile());
      for (var i = 0; i < 200 && controller.pendingDeviceWriteCount == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(controller.pendingDeviceWriteCount, 1);
      expect(machine.setProfileCalls, 0);

      release.complete();
      await held;
      final res = await pending;

      expect(res.statusCode, 200);
      expect(machine.setProfileCalls, 1);
      expect(controller.pendingDeviceWriteCount, 0);
    });

    for (final rawBody in ['[]', '"x"', '{"title": "t", "steps": [1]}']) {
      test('400 for a profile body of the wrong shape: $rawBody', () async {
        await wireWith(await bengleMachine(0x3));

        final res = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/machine/profile'),
            body: rawBody,
            headers: {HttpHeaders.contentTypeHeader: 'application/json'},
          ),
        );

        expect(res.statusCode, 400);
        final body =
            jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        expect(body['error'], 'Invalid profile');
      });
    }
  });
}
