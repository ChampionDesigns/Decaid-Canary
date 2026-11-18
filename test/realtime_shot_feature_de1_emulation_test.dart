import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/shot_sequencer.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/realtime_shot_feature/realtime_shot_feature.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/mock_device_discovery_service.dart';
import 'helpers/shot_event_storage.dart';
import 'helpers/test_de1.dart';
import 'helpers/test_scale.dart';
import 'helpers/test_scale_controller.dart';

class _De1Controller extends De1Controller {
  final TestDe1 testDe1;

  _De1Controller(this.testDe1)
    : super(controller: DeviceController([MockDeviceDiscoveryService()]));

  @override
  De1Interface connectedDe1() => testDe1;

  @override
  De1Interface? get connectedDe1OrNull => testDe1;

  @override
  Stream<De1Interface?> get de1 => BehaviorSubject.seeded(testDe1).stream;
}

Profile _profile({required bool de1Emulation}) => Profile.fromJson(
  jsonDecode(File('assets/defaultProfiles/7g_basket.json').readAsStringSync())
      as Map<String, dynamic>,
).copyWith(de1Emulation: de1Emulation);

Future<void> _pumpLiveShot(
  WidgetTester tester, {
  required bool uploadedFlag,
  required bool workflowFlag,
}) async {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final testDe1 = TestDe1()..de1EmulationSupported = true;
  await testDe1.setProfile(_profile(de1Emulation: uploadedFlag));
  final scale = TestScale();
  final scaleController = TestScaleController(scale);
  final persistence = PersistenceController(storageService: ShotEventStorage());
  final sequencer = ShotSequencer(
    scaleController: scaleController,
    de1controller: _De1Controller(testDe1),
    persistenceController: persistence,
    targetProfile: _profile(de1Emulation: workflowFlag),
    targetYield: 36,
    bypassSAW: false,
    blockOnNoScale: false,
    weightFlowMultiplier: 0,
    volumeFlowMultiplier: 0,
    stepExitArbiterEnabled: true,
  );
  addTearDown(() {
    sequencer.dispose();
    persistence.dispose();
    scaleController.dispose();
    scale.dispose();
    testDe1.dispose();
  });
  await tester.pumpWidget(
    ShadApp(
      home: RealtimeShotFeature(
        shotSequencer: sequencer,
        workflowController: WorkflowController(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the live shot shows the B-DE1 name for an emulated profile', (
    tester,
  ) async {
    await _pumpLiveShot(tester, uploadedFlag: true, workflowFlag: true);
    expect(find.text('Profile: B-DE1 · 7g basket'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the live shot shows the plain name for a native profile', (
    tester,
  ) async {
    await _pumpLiveShot(tester, uploadedFlag: false, workflowFlag: true);
    expect(find.text('Profile: 7g basket'), findsOneWidget);
    expect(find.textContaining('B-DE1'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
