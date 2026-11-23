import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/native_shaping.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/native_shaping_reporter.dart';

import '../../helpers/native_shape_machine_transport.dart';

const _espresso = espressoStateByte;
const _idle = idleStateByte;

const _timings = NativeShapingReadTimings(
  firstReadDelay: Duration(milliseconds: 20),
  retryDelay: Duration(milliseconds: 150),
  requestTimeout: Duration(milliseconds: 100),
);

Map<String, dynamic> _example() => {
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

const _exampleBlock = exampleNativeShapingBlock;

const _otherBlock = [
  0x01, 0x01, 0x32, 0x0A, 0x32, 0x14, 0x64, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

List<int> _image({
  int source = 1,
  int rule = 0,
  required int latch,
  int flags = 0,
  List<int> block = _exampleBlock,
}) => nativeShapeReportImage(
  source: source,
  rule: rule,
  latch: latch,
  flags: flags,
  block: block,
);

Profile _profile({String title = 'shaped'}) => Profile.fromJson(
  jsonDecode(File('assets/defaultProfiles/7g_basket.json').readAsStringSync())
      as Map<String, dynamic>,
).copyWith(title: title, nativeShaping: NativeShaping.fromJson(_example()));

Future<(Bengle, NativeShapeMachineTransport)> _connectBengle() async {
  final transport = NativeShapeMachineTransport();
  addTearDown(transport.dispose);
  transport.queuePaletteHydrationResponses();
  transport.queueOnConnectResponses(v13Model: 128);
  final bengle = Bengle(
    transport: transport,
    nativeShapingReadTimings: _timings,
  );
  await bengle.onConnect();
  addTearDown(bengle.onDisconnect);
  return (bengle, transport);
}

Future<void> _until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out: ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 600));

Future<void> _uploadWithBaseline(
  Bengle bengle,
  NativeShapeMachineTransport transport,
  int latch, {
  String title = 'shaped',
}) async {
  transport.image = _image(latch: latch);
  await bengle.setProfile(_profile(title: title));
}

List<String> _capture(String loggerName) {
  final lines = <String>[];
  final sub = Logger.root.onRecord
      .where((r) => r.loggerName == loggerName)
      .listen((r) => lines.add(r.message));
  addTearDown(sub.cancel);
  Logger.root.level = Level.ALL;
  return lines;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('reg 66 read', () {
    test('sends the two halves and the check read, and decodes the §3 '
        'example', () async {
      final (bengle, transport) = await _connectBengle();
      transport.image = _image(latch: 7);
      transport.writes.clear();

      transport.enterState(_espresso);
      await _until(() => nativeShapingReportedBy(bengle) != null);

      expect(transport.reportRequests.map((w) => w.data.toList()), [
        [0x03, 0x80, 0x39, 0x74, ...List.filled(16, 0)],
        [0x03, 0x80, 0x39, 0x84, ...List.filled(16, 0)],
        [0x03, 0x80, 0x39, 0x74, ...List.filled(16, 0)],
      ]);
      final report = bengle.lastNativeShapingReport!;
      expect(report.source, NativeShapingSource.profile);
      expect(report.latchCount, 7);
      expect(report.settings!.toJson(), _example());
    });

    test('starts again when the latch count changes between the first and '
        'the check read', () async {
      final (bengle, transport) = await _connectBengle();
      transport.image = _image(latch: 7);
      transport.afterRead = (i) {
        if (i == 0) transport.image = _image(latch: 8, block: _otherBlock);
      };

      transport.enterState(_espresso);
      await _until(() => nativeShapingReportedBy(bengle) != null);

      expect(transport.reportReads, 6);
      final report = bengle.lastNativeShapingReport!;
      expect(report.latchCount, 8);
      expect(report.settings, NativeShaping.fromBlockBytes(_otherBlock));
    });

    test(
      'gives no report when the latch count changes on every pass',
      () async {
        final (bengle, transport) = await _connectBengle();
        var latch = 7;
        transport.image = _image(latch: latch);
        transport.afterRead = (_) => transport.image = _image(latch: ++latch);
        final log = _capture('DE1');

        transport.enterState(_espresso);
        await _until(() => transport.reportReads >= 9);
        transport.afterRead = null;
        transport.image = null;
        await _settle();

        expect(bengle.lastNativeShapingReport, isNull);
        expect(
          log.where((l) => l.contains('changed on each of 3 passes')),
          isNotEmpty,
        );
      },
    );

    test('a rounded CLI report that breaks rule 8 keeps the report with no '
        'settings', () async {
      final (bengle, transport) = await _connectBengle();
      transport.image = _image(
        source: 0,
        latch: 3,
        flags: 1,
        block: const [
          0x01, 0x02, 0x00, 0x00, 0x32, 0x06, 0xC8, //
          0x0A, 0x96, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ],
      );

      transport.enterState(_espresso);
      await _until(() => nativeShapingReportedBy(bengle) != null);

      final report = bengle.lastNativeShapingReport!;
      expect(report.source, NativeShapingSource.cli);
      expect(report.settingsRounded, isTrue);
      expect(report.settings, isNull);
    });

    for (final (label, setUp) in [
      ('times out', (NativeShapeMachineTransport t) => t.image = null),
      (
        'throws',
        (NativeShapeMachineTransport t) =>
            t.readError = StateError('link lost'),
      ),
    ]) {
      test('a read that $label gives no report and keeps the link', () async {
        final (bengle, transport) = await _connectBengle();
        setUp(transport);
        final log = _capture('DE1');

        transport.enterState(_espresso);
        await _until(() => transport.reportRequests.length >= 2);
        await _settle();

        expect(bengle.lastNativeShapingReport, isNull);
        expect(
          log.where((l) => l.startsWith('Native shaping report read failed')),
          hasLength(2),
        );
        transport.readError = null;
        transport.image = _image(latch: 1);
        await bengle.setProfile(_profile());
        expect(transport.reportReads, greaterThan(0));
      });
    }

    test('a DE1 sends no reg 66 read', () async {
      final transport = NativeShapeMachineTransport();
      addTearDown(transport.dispose);
      transport.queueOnConnectResponses(v13Model: 1);
      final de1 = UnifiedDe1(
        transport: transport,
        nativeShapingReadTimings: _timings,
      );
      await de1.onConnect();
      transport.image = _image(latch: 7);

      await de1.setProfile(_profile());
      transport.enterState(_espresso);
      await _settle();

      expect(transport.reportRequests, isEmpty);
      expect(de1.lastNativeShapingReport, isNull);
    });
  });

  group('report life', () {
    Future<(Bengle, NativeShapeMachineTransport)> withReport() async {
      final (bengle, transport) = await _connectBengle();
      await _uploadWithBaseline(bengle, transport, 7);
      transport.image = _image(latch: 8);
      transport.enterState(_espresso);
      await _until(() => nativeShapingReportedBy(bengle) != null);
      return (bengle, transport);
    }

    test('is null after a profile upload while no shot runs', () async {
      final (bengle, transport) = await withReport();
      transport.enterState(_idle);
      await pumpEventQueue();

      await bengle.setProfile(_profile(title: 'next'));

      expect(bengle.lastNativeShapingReport, isNull);
    });

    test('is null after a raw profile write', () async {
      final (bengle, _) = await withReport();

      bengle.sendRawMessage(
        De1RawMessage(
          type: De1RawMessageType.request,
          operation: De1RawOperationType.write,
          characteristicUUID: Endpoint.headerWrite.uuid,
          payload: _hex([1, 2, 0, 0, 0]),
        ),
      );
      await pumpEventQueue();

      expect(bengle.lastNativeShapingReport, isNull);
    });

    test('is null at the next shot start', () async {
      final (bengle, transport) = await withReport();
      transport.enterState(_idle);
      transport.image = null;

      transport.enterState(_espresso);
      await pumpEventQueue();

      expect(bengle.lastNativeShapingReport, isNull);
    });
  });

  group('baseline', () {
    test('a count equal to the baseline gives no report', () async {
      final (bengle, transport) = await _connectBengle();
      await _uploadWithBaseline(bengle, transport, 7);
      final log = _capture('DE1');

      transport.enterState(_espresso);
      await _until(() => transport.reportReads >= 7);
      await _settle();

      expect(bengle.lastNativeShapingReport, isNull);
      expect(log.where((l) => l.contains('equals the baseline')), hasLength(2));
    });

    test('a new count gives the report', () async {
      final (bengle, transport) = await _connectBengle();
      await _uploadWithBaseline(bengle, transport, 7);
      transport.image = _image(latch: 8);

      transport.enterState(_espresso);
      await _until(() => nativeShapingReportedBy(bengle) != null);

      expect(bengle.lastNativeShapingReport!.latchCount, 8);
    });

    test('an equal count at the first read and a new count at the second '
        'read gives the report', () async {
      final (bengle, transport) = await _connectBengle();
      await _uploadWithBaseline(bengle, transport, 7);
      final readsBefore = transport.reportReads;
      transport.afterRead = (i) {
        if (i == readsBefore + 2) transport.image = _image(latch: 8);
      };

      transport.enterState(_espresso);
      await _until(() => nativeShapingReportedBy(bengle) != null);

      expect(bengle.lastNativeShapingReport!.latchCount, 8);
      expect(transport.reportReads - readsBefore, 6);
    });

    test('case (a): an upload during the shot keeps the accepted report, and '
        'the next baseline comes after that upload', () async {
      final (bengle, transport) = await _connectBengle();
      await _uploadWithBaseline(bengle, transport, 7);
      transport.image = _image(latch: 8);
      transport.enterState(_espresso);
      await _until(() => nativeShapingReportedBy(bengle) != null);
      final accepted = bengle.lastNativeShapingReport;

      transport.image = _image(latch: 9);
      await bengle.setProfile(_profile(title: 'during the shot'));

      expect(bengle.lastNativeShapingReport, same(accepted));
      transport.enterState(_idle);
      transport.enterState(_espresso);
      await _until(() => transport.reportReads >= 1 + 3 + 1 + 6);
      await _settle();
      expect(bengle.lastNativeShapingReport, isNull);
    });

    test('case (b): with no baseline the first good read gives the report '
        'and one log line', () async {
      final (bengle, transport) = await _connectBengle();
      transport.image = _image(latch: 7);
      final log = _capture('DE1');

      transport.enterState(_espresso);
      await _until(() => nativeShapingReportedBy(bengle) != null);

      expect(bengle.lastNativeShapingReport!.latchCount, 7);
      expect(log.where((l) => l.contains('no baseline')), hasLength(1));
    });
  });
}
