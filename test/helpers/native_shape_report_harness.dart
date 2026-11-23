import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/native_shaping.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import 'native_shape_machine_transport.dart';

const nsEspresso = espressoStateByte;
const nsIdle = idleStateByte;

const nsTimings = NativeShapingReadTimings(
  firstReadDelay: Duration(milliseconds: 20),
  retryDelay: Duration(milliseconds: 150),
  requestTimeout: Duration(milliseconds: 100),
);

Map<String, dynamic> nsExample() => {
  'version': 1,
  'pump_curve': [
    {'pressure': 1.0, 'flow': 20.0},
    {'pressure': 3.0, 'flow': 12.0},
    {'pressure': 6.0, 'flow': 6.0},
    {'pressure': 9.0, 'flow': 5.0},
    {'pressure': 12.0, 'flow': 4.0},
  ],
  'flow_tau': 0.5,
  'flow_mode': 'both',
  'pressure_tau': 0.5,
  'pressure_mode': 'both',
  'ramp_factor': 1.0,
};

const nsExampleBlock = exampleNativeShapingBlock;

const nsOtherBlock = [
  0x01, 0x01, 0x32, 0x0A, 0x32, 0x14, 0x64, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

List<int> nsImage({
  int source = 1,
  int rule = 0,
  required int latch,
  int flags = 0,
  List<int> block = nsExampleBlock,
}) => nativeShapeReportImage(
  source: source,
  rule: rule,
  latch: latch,
  flags: flags,
  block: block,
);

Profile nsProfile({String title = 'shaped'}) => Profile.fromJson(
  jsonDecode(File('assets/defaultProfiles/7g_basket.json').readAsStringSync())
      as Map<String, dynamic>,
).copyWith(title: title, nativeShaping: NativeShaping.fromJson(nsExample()));

Future<(Bengle, NativeShapeMachineTransport)> nsConnectBengle({
  int? connectLatch,
}) async {
  final transport = NativeShapeMachineTransport();
  addTearDown(transport.dispose);
  final bengle = Bengle(
    transport: transport,
    nativeShapingReadTimings: nsTimings,
  );
  addTearDown(bengle.onDisconnect);
  await nsConnect(bengle, transport, connectLatch: connectLatch);
  return (bengle, transport);
}

Future<void> nsConnect(
  Bengle bengle,
  NativeShapeMachineTransport transport, {
  int? connectLatch,
}) async {
  transport.queuePaletteHydrationResponses();
  transport.queueOnConnectResponses(v13Model: 128);
  transport.image = connectLatch == null ? null : nsImage(latch: connectLatch);
  await bengle.onConnect();
  await nsUntil(
    () => transport.reportRequests.isNotEmpty,
    reason: 'the connect read',
  );
  await Future<void>.delayed(
    nsTimings.requestTimeout + const Duration(milliseconds: 20),
  );
  transport.writes.clear();
  transport.reportReads = 0;
}

Future<void> nsUntil(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out: ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> nsSettle() =>
    Future<void>.delayed(const Duration(milliseconds: 600));

Future<void> nsUploadWithBaseline(
  Bengle bengle,
  NativeShapeMachineTransport transport,
  int latch, {
  String title = 'shaped',
}) async {
  transport.image = nsImage(latch: latch);
  await bengle.setProfile(nsProfile(title: title));
}

List<String> nsCapture(String loggerName) {
  final lines = <String>[];
  final sub = Logger.root.onRecord
      .where((r) => r.loggerName == loggerName)
      .listen((r) => lines.add(r.message));
  addTearDown(sub.cancel);
  Logger.root.level = Level.ALL;
  return lines;
}

String nsHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
