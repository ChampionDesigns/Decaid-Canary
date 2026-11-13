import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/controllers/workflow_device_sync.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/services/webserver/workflow_handler.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

class _EncoderBackedDe1 extends MockDe1 {
  _EncoderBackedDe1(this.transport)
    : machine = UnifiedDe1(transport: transport);

  final FakeBleTransport transport;
  final UnifiedDe1 machine;
  int setProfileCalls = 0;

  @override
  Future<void> setProfile(Profile profile) async {
    setProfileCalls++;
    await machine.setProfile(profile);
  }
}

Map<String, dynamic> _profileJson({
  Object temperature = 92,
  Object seconds = 30,
  Object volume = 0,
}) => {
  'version': '2',
  'title': 'Out of range',
  'beverage_type': 'espresso',
  'steps': <dynamic>[
    {
      'name': 'pour',
      'pump': 'pressure',
      'transition': 'fast',
      'volume': 0,
      'seconds': 30,
      'temperature': 92,
      'sensor': 'coffee',
      'pressure': 9.0,
    },
    {
      'name': 'too hot',
      'pump': 'pressure',
      'transition': 'fast',
      'volume': volume,
      'seconds': seconds,
      'temperature': temperature,
      'sensor': 'coffee',
      'pressure': 9.0,
    },
  ],
  'tank_temperature': 90.0,
  'target_volume_count_start': 0,
};

void main() {
  late De1Controller controller;
  late WorkflowController workflow;
  late _EncoderBackedDe1 de1;

  setUp(() async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    addTearDown(deviceController.dispose);
    controller = De1Controller(controller: deviceController);
    addTearDown(controller.dispose);
    final transport = FakeBleTransport();
    addTearDown(transport.dispose);
    de1 = _EncoderBackedDe1(transport);
    await controller.connectToDe1(de1);
    await controller.initSettled.firstWhere((generation) => generation != null);
    workflow = WorkflowController();
  });

  group('POST /api/v1/machine/profile', () {
    late Handler handler;

    setUp(() async {
      final settingsController = SettingsController(MockSettingsService());
      await settingsController.loadSettings();
      final app = Router().plus;
      De1Handler(
        controller: controller,
        settingsController: settingsController,
        scaleController: TestScaleController(TestScale()),
        workflowController: workflow,
      ).addRoutes(app);
      handler = app.call;
    });

    for (final (label, json, field, shown)
        in <(String, Map<String, dynamic>, String, String)>[
          (
            'a step temperature of 130',
            _profileJson(temperature: 130),
            'temperature',
            '130.0',
          ),
          (
            'a step temperature of "NaN"',
            _profileJson(temperature: 'NaN'),
            'temperature',
            'NaN',
          ),
          (
            'step seconds of -1e308',
            _profileJson(seconds: -1e308),
            'seconds',
            '-1e+308',
          ),
          ('step seconds of -1', _profileJson(seconds: -1), 'seconds', '-1'),
          ('a step volume of -5', _profileJson(volume: -5), 'volume', '-5'),
        ]) {
      test('$label answers 400 and writes nothing', () async {
        de1.transport.writes.clear();
        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/machine/profile'),
            body: jsonEncode(json),
            headers: {HttpHeaders.contentTypeHeader: 'application/json'},
          ),
        );

        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], 'Unsupported profile');
        expect(
          body['message'],
          allOf(contains('step 2'), contains(field), contains(shown)),
        );
        expect(de1.setProfileCalls, 1);
        expect(de1.transport.writes, isEmpty);
      });
    }
  });

  group('PUT /api/v1/workflow', () {
    for (final (label, json) in <(String, Map<String, dynamic>)>[
      ('a step temperature of 130', _profileJson(temperature: 130)),
      ('step seconds of -1e308', _profileJson(seconds: -1e308)),
      ('step seconds of -1', _profileJson(seconds: -1)),
      ('a step volume of -5', _profileJson(volume: -5)),
    ]) {
      test('with $label answers 200 first; WorkflowDeviceSync then tries once '
          'and parks', () async {
        final sync = WorkflowDeviceSync(
          workflowController: workflow,
          de1Controller: controller,
          retryDelays: const [
            Duration(milliseconds: 20),
            Duration(milliseconds: 40),
          ],
        );
        addTearDown(sync.dispose);
        final app = Router().plus;
        WorkflowHandler(
          controller: workflow,
          de1controller: controller,
        ).addRoutes(app);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        de1.setProfileCalls = 0;
        de1.transport.writes.clear();

        final response = await app.call(
          Request(
            'PUT',
            Uri.parse('http://localhost/api/v1/workflow'),
            body: jsonEncode({'profile': json}),
            headers: {'content-type': 'application/json'},
          ),
        );

        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString());
        expect(body['profile']['title'], 'Out of range');

        for (var i = 0; i < 100 && de1.setProfileCalls == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(de1.setProfileCalls, 1);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(de1.setProfileCalls, 1, reason: 'a refused profile is parked');
        expect(de1.transport.writes, isEmpty);
      });
    }
  });
}
