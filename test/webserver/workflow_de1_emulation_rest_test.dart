import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/controllers/workflow_device_sync.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_emulation_reporter.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/services/webserver/workflow_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/fake_ble_transport.dart';
import '../helpers/mock_device_discovery_service.dart';

class _BengleBackedDe1 extends MockDe1 {
  _BengleBackedDe1(this.bengle);

  final Bengle bengle;

  @override
  Future<void> setProfile(Profile profile) => bengle.setProfile(profile);
}

Map<String, dynamic> _bundledBestPractice() => jsonDecode(
  File('assets/defaultProfiles/best_practice.json').readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  late FakeBleTransport transport;
  late Bengle bengle;
  late WorkflowController workflowController;
  late Handler handler;

  setUp(() async {
    transport = FakeBleTransport();
    addTearDown(transport.dispose);
    bengle = Bengle(transport: transport);
    transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
    transport.queueOnConnectResponses(v13Model: 128);
    transport.queuePaletteHydrationResponses();
    await bengle.onConnect();

    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    addTearDown(deviceController.dispose);
    final de1Controller = De1Controller(controller: deviceController);
    addTearDown(de1Controller.dispose);
    workflowController = WorkflowController();
    final sync = WorkflowDeviceSync(
      workflowController: workflowController,
      de1Controller: de1Controller,
    );
    addTearDown(sync.dispose);
    await de1Controller.connectToDe1(_BengleBackedDe1(bengle));
    await de1Controller.initSettled.firstWhere((g) => g != null);

    final app = Router().plus;
    WorkflowHandler(
      controller: workflowController,
      de1controller: de1Controller,
    ).addRoutes(app);
    handler = app.call;
  });

  Future<Map<String, dynamic>> send(String method, [Object? body]) async {
    final response = await handler(
      Request(
        method,
        Uri.parse('http://localhost/api/v1/workflow'),
        body: body == null ? null : jsonEncode(body),
        headers: {'content-type': 'application/json'},
      ),
    );
    expect(response.statusCode, 200);
    return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  }

  List<Uint8List> tailsFor(int stepCount) => transport.writes
      .where(
        (w) =>
            w.characteristicUUID == Endpoint.frameWrite.uuid &&
            w.data.length == 8 &&
            w.data[0] == stepCount,
      )
      .map((w) => w.data)
      .toList();

  Future<int> lastTailByte3(int stepCount, {required int want}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      final tails = tailsFor(stepCount);
      if (tails.isNotEmpty &&
          tails.last[3] == want &&
          de1EmulationSentBy(bengle) == (want == 1)) {
        return want;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final tails = tailsFor(stepCount);
    return tails.isEmpty ? -1 : tails.last[3];
  }

  Future<void> putEmulatedBestPractice(Map<String, dynamic> native) async {
    final body = await send('PUT', {
      'profile': {...native, 'de1_emulation': true},
    });
    expect(body['profile']['de1_emulation'], isTrue);
    final steps = (native['steps'] as List).length;
    expect(await lastTailByte3(steps, want: 1), 1);
    expect(de1EmulationSentBy(bengle), isTrue);
  }

  test('the bundled native profile without the key clears DE1 emulation '
      'in the workflow and in the tail frame', () async {
    final native = _bundledBestPractice();
    expect(native.containsKey('de1_emulation'), isFalse);
    final steps = (native['steps'] as List).length;
    await putEmulatedBestPractice(native);

    await send('PUT', {'profile': native});
    final served = await send('GET');

    expect(served['profile'].containsKey('de1_emulation'), isFalse);
    expect(await lastTailByte3(steps, want: 0), 0);
    expect(de1EmulationSentBy(bengle), isFalse);
  });

  test('a partial profile patch without the key keeps DE1 emulation', () async {
    final native = _bundledBestPractice();
    final steps = (native['steps'] as List).length;
    await putEmulatedBestPractice(native);
    final tailsBefore = tailsFor(steps).length;

    await send('PUT', {
      'profile': {'target_weight': 40.0},
    });
    final served = await send('GET');

    expect(served['profile']['de1_emulation'], isTrue);
    expect(served['profile']['target_weight'], 40.0);
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while ((tailsFor(steps).length == tailsBefore ||
            !de1EmulationSentBy(bengle)) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      tailsFor(steps).length,
      greaterThan(tailsBefore),
      reason: 'the patch did not write a new profile tail frame',
    );
    expect(tailsFor(steps).last[3], 1);
    expect(de1EmulationSentBy(bengle), isTrue);
  });
}
