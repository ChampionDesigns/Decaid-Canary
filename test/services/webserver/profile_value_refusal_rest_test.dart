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

const _placeholder = 'NON_FINITE_PLACEHOLDER';

String _bodyWithNonFiniteStep(
  String field,
  String literal, {
  bool asWorkflow = false,
}) {
  final profile = _profileJson();
  (profile['steps'] as List<dynamic>)[1][field] = _placeholder;
  return jsonEncode(asWorkflow ? {'profile': profile} : profile)
      .replaceFirst('"$_placeholder"', literal);
}

const _nonFiniteRestCases = <(String, String, String)>[
  ('a step temperature of "NaN"', 'temperature', '"NaN"'),
  ('a step pressure of "NaN"', 'pressure', '"NaN"'),
  ('step seconds of 1e400', 'seconds', '1e400'),
  ('a step pressure of -1e400', 'pressure', '-1e400'),
];

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
            'step seconds of -1e308',
            _profileJson(seconds: -1e308),
            'seconds',
            '-1e+308',
          ),
          ('step seconds of -1', _profileJson(seconds: -1), 'seconds', '-1'),
          ('a step volume of -5', _profileJson(volume: -5), 'volume', '-5'),
          (
            'a step volume of 2000',
            _profileJson(volume: 2000),
            'volume',
            '2000',
          ),
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

    for (final (label, field, literal) in _nonFiniteRestCases) {
      test('$label answers 400 at parse and sends nothing', () async {
        de1.transport.writes.clear();
        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/machine/profile'),
            body: _bodyWithNonFiniteStep(field, literal),
            headers: {HttpHeaders.contentTypeHeader: 'application/json'},
          ),
        );

        expect(response.statusCode, 400);
        expect(jsonDecode(await response.readAsString()), {
          'error': 'Invalid profile',
          'message': 'FormatException: step "$field" must be a finite number',
        });
        expect(de1.setProfileCalls, 0);
        expect(de1.transport.writes, isEmpty);
      });
    }

    test('a power step with limiter value -1 on a Bengle answers 400 and '
        'writes nothing', () async {
      de1.transport.queueOnConnectResponses(
        v13Model: 128,
        profileModeCaps: 0x7,
      );
      await de1.machine.onConnect();
      expect(de1.machine.isBengle, isTrue);
      de1.transport.writes.clear();

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/machine/profile'),
          body: jsonEncode({
            'version': '2',
            'title': 'Power cap below zero',
            'beverage_type': 'espresso',
            'steps': <dynamic>[
              {
                'name': 'power pour',
                'pump': 'power',
                'transition': 'fast',
                'volume': 0,
                'seconds': 25,
                'temperature': 93,
                'sensor': 'coffee',
                'power': 2.0,
                'limiter': {'value': -1, 'range': 0},
              },
            ],
            'tank_temperature': 90.0,
            'target_volume_count_start': 0,
          }),
          headers: {HttpHeaders.contentTypeHeader: 'application/json'},
        ),
      );

      expect(response.statusCode, 400);
      final body = jsonDecode(await response.readAsString());
      expect(body['error'], 'Unsupported profile');
      expect(
        body['message'],
        allOf(contains('step 1'), contains('limiter value'), contains('-1')),
      );
      expect(de1.setProfileCalls, 1);
      expect(de1.transport.writes, isEmpty);
    });
  });

  group('POST /api/v1/machine/profile power exit', () {
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

    test(
      'a 30 W power exit on a Bengle answers 400 and writes nothing',
      () async {
        de1.transport.queueOnConnectResponses(
          v13Model: 128,
          profileModeCaps: 0xF,
        );
        await de1.machine.onConnect();
        expect(de1.machine.isBengle, isTrue);
        de1.transport.writes.clear();

        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/machine/profile'),
            body: jsonEncode({
              'version': '2',
              'title': 'Power exit too high',
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
                  'exit': {'type': 'power', 'condition': 'over', 'value': 30},
                },
              ],
              'tank_temperature': 90.0,
              'target_volume_count_start': 0,
            }),
            headers: {HttpHeaders.contentTypeHeader: 'application/json'},
          ),
        );

        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], 'Unsupported profile');
        expect(
          body['message'],
          allOf(
            contains('step 1'),
            contains('power exit value'),
            contains('30'),
          ),
        );
        expect(de1.setProfileCalls, 1);
        expect(de1.transport.writes, isEmpty);
      },
    );
  });

  group('PUT /api/v1/workflow with a non-finite step value', () {
    for (final (label, field, literal) in _nonFiniteRestCases) {
      test('$label answers 400, keeps the earlier workflow and uploads '
          'nothing', () async {
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
        Future<Response> getWorkflow() async => app.call(
          Request('GET', Uri.parse('http://localhost/api/v1/workflow')),
        );
        final before = await (await getWorkflow()).readAsString();

        final response = await app.call(
          Request(
            'PUT',
            Uri.parse('http://localhost/api/v1/workflow'),
            body: _bodyWithNonFiniteStep(field, literal, asWorkflow: true),
            headers: {'content-type': 'application/json'},
          ),
        );

        expect(response.statusCode, 400);
        expect(jsonDecode(await response.readAsString()), {
          'error': 'Invalid request',
          'message': 'FormatException: step "$field" must be a finite number',
        });
        final after = await getWorkflow();
        expect(after.statusCode, 200);
        expect(await after.readAsString(), before);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(de1.setProfileCalls, 0);
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
      ('a step volume of 2000', _profileJson(volume: 2000)),
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
