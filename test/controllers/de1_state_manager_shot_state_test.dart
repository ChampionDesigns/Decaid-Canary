import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/de1_state_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/native_shaping.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/native_shape_machine_transport.dart';
import '../helpers/non_de1_profile_step.dart';
import '../helpers/test_de1.dart';

class _BengleReportingDe1 extends TestDe1 {
  _BengleReportingDe1(this.bengle);

  final Bengle bengle;

  @override
  NativeShapingReport? get lastNativeShapingReport =>
      bengle.lastNativeShapingReport;
}

class _TestDe1Controller extends De1Controller {
  final BehaviorSubject<De1Interface?> de1Subject = BehaviorSubject.seeded(
    null,
  );
  De1Interface? current;
  int connectedLookupCount = 0;
  int? failConnectedLookupAt;

  _TestDe1Controller({required super.controller});

  @override
  Stream<De1Interface?> get de1 => de1Subject.stream;

  @override
  De1Interface connectedDe1() {
    connectedLookupCount++;
    if (connectedLookupCount == failConnectedLookupAt) {
      throw 'machine info unavailable';
    }
    final de1 = current;
    if (de1 == null) throw 'no de1 connected';
    return de1;
  }

  @override
  De1Interface? get connectedDe1OrNull => current;

  void connect(De1Interface de1) {
    current = de1;
    de1Subject.add(de1);
  }

  void disconnect() {
    current = null;
    de1Subject.add(null);
  }
}

class _CapturingStorageService implements StorageService {
  final List<ShotRecord> storedShots = [];

  @override
  Future<void> storeShot(ShotRecord record) async => storedShots.add(record);
  @override
  Future<void> updateShot(ShotRecord record) async {}
  @override
  Future<void> deleteShot(String id) async {}
  @override
  Future<List<String>> getShotIds() async => [];
  @override
  Future<List<ShotRecord>> getAllShots() async => [];
  @override
  Future<ShotRecord?> getShot(String id) async => null;
  @override
  Future<void> storeCurrentWorkflow(Workflow workflow) async {}
  @override
  Future<Workflow?> loadCurrentWorkflow() async => null;
  @override
  Future<List<ShotRecord>> getShotsPaginated({
    int limit = 20,
    int offset = 0,
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    double? minEnjoyment,
    bool ascending = false,
  }) async => [];
  @override
  Future<int> countShots({
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    double? minEnjoyment,
  }) async => 0;
  @override
  Future<ShotRecord?> getLatestShot() async => null;
  @override
  Future<ShotRecord?> getLatestShotMeta() async => null;
  @override
  Future<void> storeSteam(SteamRecord record) async {}
  @override
  Future<void> updateSteam(SteamRecord record) async {}
  @override
  Future<void> deleteSteam(String id) async {}
  @override
  Future<List<String>> getSteamIds() async => [];
  @override
  Future<List<SteamRecord>> getAllSteams() async => [];
  @override
  Future<SteamRecord?> getSteam(String id) async => null;
  @override
  Future<SteamRecord?> getLatestSteam() async => null;
  @override
  Future<SteamRecord?> getLatestSteamMeta() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDe1 testDe1;
  late _TestDe1Controller de1Controller;
  late ScaleController scaleController;
  late _CapturingStorageService storage;
  late WorkflowController workflowController;
  late De1StateManager manager;
  late List<ShotStateEvent> events;
  late StreamSubscription<ShotStateEvent> eventsSub;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    testDe1 = TestDe1();
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = _TestDe1Controller(controller: deviceController);
    scaleController = ScaleController();
    storage = _CapturingStorageService();
    workflowController = WorkflowController();

    final settingsService = MockSettingsService();
    await settingsService.updateGatewayMode(GatewayMode.tracking);
    final settingsController = SettingsController(settingsService);
    await settingsController.loadSettings();

    final connectionManager = ConnectionManager(
      deviceScanner: deviceController,
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settingsController,
    );

    manager = De1StateManager(
      de1Controller: de1Controller,
      scaleController: scaleController,
      workflowController: workflowController,
      persistenceController: PersistenceController(storageService: storage),
      settingsController: settingsController,
      connectionManager: connectionManager,
      navigatorKey: GlobalKey<NavigatorState>(),
    );

    events = [];
    eventsSub = de1Controller.shotState.listen(events.add);

    de1Controller.connect(testDe1);
    await pump();
  });

  tearDown(() async {
    await eventsSub.cancel();
    manager.dispose();
    await testDe1.dispose();
  });

  Future<void> driveShot() async {
    testDe1.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.preparingForShot,
    );
    await pump();
    testDe1.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.pouring,
    );
    await pump();
    testDe1.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.pouringDone,
    );
    await pump();
  }

  test('forwards a full shot lifecycle onto De1Controller.shotState and '
      'persists a matching record', () async {
    await driveShot();

    final states = events
        .where((e) => e.event == 'state')
        .map((e) => e.state)
        .toList();
    expect(states, contains(ShotState.preheating));
    expect(states, contains(ShotState.pouring));
    expect(states, contains(ShotState.finished));
    expect(
      states.last,
      ShotState.idle,
      reason: 'the feed re-seeds idle after cleanup',
    );

    final decision = events.singleWhere((e) => e.event == 'decision');
    expect(decision.decision?.kind, ShotDecisionKind.stop);
    expect(decision.decision?.reason, ShotDecisionReason.machineEnded);
    expect(decision.shotId, isNotNull);
    expect(
      decision.timestamp,
      DateTime(2026, 1, 15, 8, 0),
      reason:
          'frames carry the triggering snapshot timestamp (TestDe1 stamps '
          'all snapshots with this fixed time), not publish wall clock, so '
          'clients can align decisions with snapshot telemetry',
    );

    expect(storage.storedShots, hasLength(1));
    final record = storage.storedShots.single;
    expect(record.stopReason, 'machineEnded');
    expect(record.workflow.machine?.flowCalibration, 1.0);
    expect(
      record.workflow.machine?.provenanceStatus,
      WorkflowMachineProvenanceStatus.captured,
    );
    expect(record.workflow.machine?.serialNumber, '1');
    expect(record.workflow.machine?.model, '1');
    expect(record.workflow.machine?.firmwareVersion, '1');
    expect(
      record.id,
      decision.shotId,
      reason:
          'the persisted record id must match the live shotId so '
          'clients can correlate the stream to the saved shot',
    );
  });

  test(
    'shot completion stores each complete grinder workflow snapshot',
    () async {
      workflowController.setWorkflow(
        workflowController.currentWorkflow.copyWith(
          id: workflowController.currentWorkflow.id,
          context: const WorkflowContext(
            grinderId: 'grinder-1',
            grinderModel: 'EG1',
            grinderBurrs: 'Core',
            grinderSetting: '12.5',
            grinderRpm: 1200,
            extras: {
              'plugin.grinder': {
                'feedingRate': 4.5,
                'rpmProfile': [900, 1200],
              },
            },
          ),
        ),
      );

      await driveShot();
      final first = storage.storedShots.single;

      workflowController.setWorkflow(
        workflowController.currentWorkflow.copyWith(
          id: workflowController.currentWorkflow.id,
          context: const WorkflowContext(
            grinderId: 'grinder-1',
            grinderModel: 'EG1',
            grinderBurrs: 'Core',
            grinderSetting: '13.0',
            grinderRpm: 1300,
            extras: {
              'plugin.grinder': {
                'feedingRate': 5.5,
                'rpmProfile': [1000, 1300],
              },
            },
          ),
        ),
      );
      testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
      await pump();
      events.clear();
      await driveShot();

      expect(storage.storedShots, hasLength(2));
      expect(first.workflow.context?.grinderSetting, '12.5');
      expect(first.workflow.context?.grinderRpm, 1200);
      expect(first.workflow.context?.extras, {
        'plugin.grinder': {
          'feedingRate': 4.5,
          'rpmProfile': [900, 1200],
        },
      });
      final second = storage.storedShots[1];
      expect(second.workflow.context?.grinderSetting, '13.0');
      expect(second.workflow.context?.grinderRpm, 1300);
      expect(second.workflow.context?.extras, {
        'plugin.grinder': {
          'feedingRate': 5.5,
          'rpmProfile': [1000, 1300],
        },
      });
    },
  );

  group('DE1 emulation provenance', () {
    Future<ShotRecord> shotWith({
      required bool profileFlag,
      required bool support,
    }) async {
      final workflow = workflowController.currentWorkflow;
      workflowController.setWorkflow(
        workflow.copyWith(
          id: workflow.id,
          profile: workflow.profile.copyWith(de1Emulation: profileFlag),
        ),
      );
      testDe1.de1EmulationSupported = support;
      await testDe1.setProfile(workflowController.currentWorkflow.profile);
      await driveShot();
      return storage.storedShots.single;
    }

    test('the profile on the machine decides, not the workflow', () async {
      final workflow = workflowController.currentWorkflow;
      testDe1.de1EmulationSupported = true;
      await testDe1.setProfile(workflow.profile.copyWith(de1Emulation: true));
      workflowController.setWorkflow(
        workflow.copyWith(
          id: workflow.id,
          profile: workflow.profile.copyWith(de1Emulation: false),
        ),
      );
      await driveShot();
      expect(storage.storedShots.single.de1Emulation, isTrue);
    });

    test('an emulated workflow profile that the machine did not get records '
        'a native shot', () async {
      final workflow = workflowController.currentWorkflow;
      testDe1.de1EmulationSupported = true;
      await testDe1.setProfile(workflow.profile.copyWith(de1Emulation: false));
      workflowController.setWorkflow(
        workflow.copyWith(
          id: workflow.id,
          profile: workflow.profile.copyWith(de1Emulation: true),
        ),
      );
      await driveShot();
      expect(storage.storedShots.single.de1Emulation, isFalse);
    });

    test('flag ON and machine support record an emulated shot', () async {
      final record = await shotWith(profileFlag: true, support: true);
      expect(record.de1Emulation, isTrue);
      expect(record.workflow.machine?.de1Emulation, isTrue);
      expect(record.toJson()['de1Emulation'], isTrue);
      expect(record.displayProfileTitle, startsWith('B-DE1 · '));
    });

    for (final (flag, support) in [
      (true, false),
      (false, true),
      (false, false),
    ]) {
      test('flag $flag and support $support record a native shot', () async {
        final record = await shotWith(profileFlag: flag, support: support);
        expect(record.de1Emulation, isFalse);
        expect(record.toJson().containsKey('de1Emulation'), isFalse);
        expect(record.displayProfileTitle, record.workflow.profile.title);
      });
    }

    test('a machine profile with a step that is not pressure or flow '
        'records a native shot', () async {
      final workflow = workflowController.currentWorkflow;
      final flagged = workflow.profile.copyWith(de1Emulation: true);
      testDe1.de1EmulationSupported = true;
      await testDe1.setProfile(
        flagged.copyWith(steps: [...flagged.steps, const NonDe1ProfileStep()]),
      );
      workflowController.setWorkflow(
        workflow.copyWith(id: workflow.id, profile: flagged),
      );
      await driveShot();
      final record = storage.storedShots.single;
      expect(record.de1Emulation, isFalse);
      expect(record.toJson().containsKey('de1Emulation'), isFalse);
      expect(record.displayProfileTitle, flagged.title);
      expect(record.workflow.profile.de1Emulation, isTrue);
    });

    test('the recorded profile keeps its title and flag', () async {
      final title = workflowController.currentWorkflow.profile.title;
      final record = await shotWith(profileFlag: true, support: true);
      expect(record.workflow.profile.title, title);
      expect(record.workflow.profile.de1Emulation, isTrue);
      expect(workflowController.currentWorkflow.profile.title, title);
      expect(
        workflowController.currentWorkflow.machine?.de1Emulation,
        isNot(isTrue),
      );
    });

    test('a repeated emulated shot does not carry its flag over', () async {
      final workflow = workflowController.currentWorkflow;
      workflowController.setWorkflow(
        workflow.copyWith(
          id: workflow.id,
          machine: const WorkflowMachine(de1Emulation: true),
        ),
      );
      final record = await shotWith(profileFlag: false, support: true);
      expect(record.de1Emulation, isFalse);
    });

    test(
      'a profile change after the shot starts does not change the flag',
      () async {
        final workflow = workflowController.currentWorkflow;
        workflowController.setWorkflow(
          workflow.copyWith(
            id: workflow.id,
            profile: workflow.profile.copyWith(de1Emulation: true),
          ),
        );
        testDe1.de1EmulationSupported = true;
        await testDe1.setProfile(workflowController.currentWorkflow.profile);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.preparingForShot,
        );
        await pump();
        final started = workflowController.currentWorkflow;
        final changed = started.profile.copyWith(de1Emulation: false);
        workflowController.setWorkflow(
          started.copyWith(id: started.id, profile: changed),
        );
        await testDe1.setProfile(changed);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        await pump();
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        await pump();

        expect(storage.storedShots.single.de1Emulation, isTrue);
      },
    );

    test('a workflow change during the shot keeps the recipe and the mode '
        'that the shot started with', () async {
      final workflow = workflowController.currentWorkflow;
      final profileA = workflow.profile.copyWith(
        title: 'Recipe A',
        de1Emulation: true,
      );
      workflowController.setWorkflow(
        workflow.copyWith(id: workflow.id, profile: profileA),
      );
      testDe1.de1EmulationSupported = true;
      await testDe1.setProfile(profileA);
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.preparingForShot,
      );
      await pump();

      final started = workflowController.currentWorkflow;
      final profileB = started.profile.copyWith(
        title: 'Recipe B',
        de1Emulation: false,
      );
      workflowController.setWorkflow(
        started.copyWith(id: started.id, profile: profileB),
      );
      await testDe1.setProfile(profileB);
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouring,
      );
      await pump();
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouringDone,
      );
      await pump();

      final record = storage.storedShots.single;
      expect(record.workflow.profile, profileA);
      expect(record.workflow.profile.title, 'Recipe A');
      expect(record.de1Emulation, isTrue);
      expect(record.displayProfileTitle, 'B-DE1 · Recipe A');
      expect(workflowController.currentWorkflow.profile, profileB);
    });
  });

  group('native shaping report', () {
    NativeShapingReport report(int latchCount) =>
        NativeShapingReport.fromBytes([
          1,
          0,
          latchCount,
          0,
          ...[0x01, 0x05, 0x19, 0x19, 0x32, 0x0A, 0xC8],
          ...[0x1E, 0x78, 0x3C, 0x3C, 0x5A, 0x32, 0x78],
          ...[0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
          ...List.filled(7, 0),
        ]);

    test('a shot without a report has no nativeShaping key', () async {
      await driveShot();

      final record = storage.storedShots.single;
      expect(record.workflow.machine?.nativeShaping, isNull);
      final machine = record.workflow.toJson()['machine'] as Map;
      expect(machine.containsKey('nativeShaping'), isFalse);
    });

    test('the report that the machine gives during the shot lands in '
        'workflow.machine.nativeShaping', () async {
      testDe1.lastNativeShapingReport = report(4);
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.preparingForShot,
      );
      await pump();
      testDe1.lastNativeShapingReport = report(5);
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouring,
      );
      await pump();
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouringDone,
      );
      await pump();

      final record = storage.storedShots.single;
      expect(record.workflow.machine?.nativeShaping, report(5));
      expect(
        record.workflow.machine?.provenanceStatus,
        WorkflowMachineProvenanceStatus.captured,
      );
      final machine = record.workflow.toJson()['machine'] as Map;
      expect(machine['nativeShaping'], report(5).toJson());
      expect(workflowController.currentWorkflow.machine?.nativeShaping, isNull);
    });

    test('a shot after a cleared report does not keep the old one', () async {
      testDe1.lastNativeShapingReport = report(1);
      await driveShot();
      testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
      await pump();
      testDe1.lastNativeShapingReport = null;
      await driveShot();

      expect(storage.storedShots, hasLength(2));
      expect(storage.storedShots[0].workflow.machine?.nativeShaping, report(1));
      expect(storage.storedShots[1].workflow.machine?.nativeShaping, isNull);
    });

    Future<(Bengle, NativeShapeMachineTransport)> connectReportingBengle({
      List<int>? image,
      Object? readError,
    }) async {
      final transport = NativeShapeMachineTransport()
        ..image = image
        ..readError = readError;
      addTearDown(transport.dispose);
      transport.queuePaletteHydrationResponses();
      transport.queueOnConnectResponses(v13Model: 128);
      final bengle = Bengle(
        transport: transport,
        nativeShapingReadTimings: const NativeShapingReadTimings(
          firstReadDelay: Duration(milliseconds: 10),
          retryDelay: Duration(milliseconds: 50),
          requestTimeout: Duration(milliseconds: 50),
        ),
      );
      await bengle.onConnect();
      addTearDown(bengle.onDisconnect);
      await testDe1.dispose();
      testDe1 = _BengleReportingDe1(bengle);
      de1Controller.connect(testDe1);
      await pump();
      return (bengle, transport);
    }

    test('a Bengle report with a new latch count is saved with the shot, '
        'source profile', () async {
      final (bengle, transport) = await connectReportingBengle(
        image: nativeShapeReportImage(latch: 9),
      );

      transport.emitNotification(Endpoint.stateInfo, [espressoStateByte, 0]);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (bengle.lastNativeShapingReport == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await driveShot();

      final saved = storage.storedShots.single.workflow.machine?.nativeShaping;
      expect(saved, isNotNull);
      expect(saved!.source, NativeShapingSource.profile);
      expect(saved.latchCount, 9);
      final machine =
          storage.storedShots.single.workflow.toJson()['machine'] as Map;
      expect((machine['nativeShaping'] as Map)['source'], 'profile');
    });

    for (final action in ['a profile upload', 'a raw profile write']) {
      test('$action between espresso end and the shot save keeps the report '
          'in the saved record', () async {
        final (bengle, transport) = await connectReportingBengle(
          image: nativeShapeReportImage(latch: 9),
        );
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.preparingForShot,
        );
        await pump();
        transport.emitNotification(Endpoint.stateInfo, [espressoStateByte, 0]);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (bengle.lastNativeShapingReport == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(bengle.lastNativeShapingReport, isNotNull);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        await pump();
        transport.emitNotification(Endpoint.stateInfo, [idleStateByte, 0]);
        await pump();

        if (action == 'a profile upload') {
          await bengle.setProfile(
            workflowController.currentWorkflow.profile.copyWith(title: 'next'),
          );
        } else {
          bengle.sendRawMessage(
            De1RawMessage(
              type: De1RawMessageType.request,
              operation: De1RawOperationType.write,
              characteristicUUID: Endpoint.headerWrite.uuid,
              payload: '0102000000',
            ),
          );
        }
        await pump();
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        await pump();

        final saved =
            storage.storedShots.single.workflow.machine?.nativeShaping;
        expect(saved, isNotNull);
        expect(saved!.latchCount, 9);
        final machine =
            storage.storedShots.single.workflow.toJson()['machine'] as Map;
        expect((machine['nativeShaping'] as Map)['latchCount'], 9);
      });
    }

    for (final (label, image, error) in [
      ('times out', null, null),
      ('throws', null, StateError('link lost')),
    ]) {
      test('a Bengle reg 66 read that $label gives no report and the shot is '
          'still saved', () async {
        final (bengle, transport) = await connectReportingBengle(
          image: image,
          readError: error,
        );

        transport.emitNotification(Endpoint.stateInfo, [espressoStateByte, 0]);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await driveShot();

        expect(transport.reportRequests, isNotEmpty);
        expect(bengle.lastNativeShapingReport, isNull);
        final record = storage.storedShots.single;
        expect(record.workflow.machine?.nativeShaping, isNull);
      });
    }
  });

  test(
    'failed machine capture persists unavailable instead of stale identity',
    () async {
      workflowController.setWorkflow(
        workflowController.currentWorkflow.copyWith(
          machine: const WorkflowMachine(serialNumber: 'stale-machine'),
        ),
      );
      de1Controller.failConnectedLookupAt =
          de1Controller.connectedLookupCount + 3;

      await driveShot();

      expect(storage.storedShots, hasLength(1));
      expect(storage.storedShots.single.workflow.machine?.toJson(), {
        'provenanceStatus': 'unavailable',
      });
    },
  );

  test('keeps forwarding across consecutive shots (per-shot sequencer '
      'recreation)', () async {
    await driveShot();
    final firstShotId = events.singleWhere((e) => e.event == 'decision').shotId;

    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump();

    events.clear();
    await driveShot();

    final decision = events.singleWhere((e) => e.event == 'decision');
    expect(decision.decision?.reason, ShotDecisionReason.machineEnded);
    expect(
      decision.shotId,
      isNot(firstShotId),
      reason: 'each shot gets its own id',
    );
    expect(storage.storedShots, hasLength(2));
  });

  test('aborting during preheat tears the sequencer down without persisting, '
      'and the next shot gets a fresh id', () async {
    testDe1.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.preparingForShot,
    );
    await pump();
    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump();

    expect(
      events.any(
        (e) =>
            e.event == 'decision' && e.decision?.kind == ShotDecisionKind.abort,
      ),
      isTrue,
      reason:
          'the aborted preheat emits an abort decision, not a stuck '
          'preheating frame',
    );
    expect(
      events.where((e) => e.event == 'terminal'),
      isEmpty,
      reason:
          'the abort decision is the terminal signal; no duplicate '
          'disconnected frame',
    );
    expect(events.last.state, ShotState.idle);
    expect(events.last.shotId, isNull, reason: 'feed re-seeds idle');
    expect(storage.storedShots, isEmpty);

    events.clear();
    await driveShot();

    expect(storage.storedShots, hasLength(1));
    final decision = events.singleWhere((e) => e.event == 'decision');
    expect(storage.storedShots.single.id, decision.shotId);
    expect(storage.storedShots.single.stopReason, 'machineEnded');
  });

  test(
    'publishes a terminal frame when the machine disconnects mid-shot',
    () async {
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.preparingForShot,
      );
      await pump();
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouring,
      );
      await pump();

      de1Controller.disconnect();
      await pump();

      final terminal = events.singleWhere((e) => e.event == 'terminal');
      expect(terminal.decision?.reason, ShotDecisionReason.disconnected);
      expect(
        events.last.state,
        ShotState.idle,
        reason:
            'the feed re-seeds idle so late joiners never see a stale '
            'pouring frame',
      );
      expect(
        storage.storedShots,
        isEmpty,
        reason: 'a disconnected shot is torn down, not persisted',
      );
    },
  );
}
