import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/native_shaping.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/native_shaping_reporter.dart';

import '../../helpers/native_shape_machine_transport.dart';
import '../../helpers/native_shape_report_harness.dart';

void main() {
  group('reg 66 read', () {
    test('sends the two halves and the check read, and decodes the §3 '
        'example', () async {
      final (bengle, transport) = await nsConnectBengle();
      transport.image = nsImage(latch: 7);
      transport.writes.clear();

      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);

      expect(transport.reportRequests.map((w) => w.data.toList()), [
        [0x03, 0x80, 0x39, 0x74, ...List.filled(16, 0)],
        [0x03, 0x80, 0x39, 0x84, ...List.filled(16, 0)],
        [0x03, 0x80, 0x39, 0x74, ...List.filled(16, 0)],
      ]);
      final report = bengle.lastNativeShapingReport!;
      expect(report.source, NativeShapingSource.profile);
      expect(report.latchCount, 7);
      expect(report.settings!.toJson(), nsExample());
    });

    test('starts again when the latch count changes between the first and '
        'the check read', () async {
      final (bengle, transport) = await nsConnectBengle();
      transport.image = nsImage(latch: 7);
      transport.afterRead = (i) {
        if (i == 0) transport.image = nsImage(latch: 8, block: nsOtherBlock);
      };

      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);

      expect(transport.reportReads, 6);
      final report = bengle.lastNativeShapingReport!;
      expect(report.latchCount, 8);
      expect(report.settings, NativeShaping.fromBlockBytes(nsOtherBlock));
    });

    test(
      'gives no report when the latch count changes on every pass',
      () async {
        final (bengle, transport) = await nsConnectBengle();
        var latch = 7;
        transport.image = nsImage(latch: latch);
        transport.afterRead = (_) => transport.image = nsImage(latch: ++latch);
        final log = nsCapture('DE1');

        transport.enterState(nsEspresso);
        await nsUntil(() => transport.reportReads >= 9);
        transport.afterRead = null;
        transport.image = null;
        await nsSettle();

        expect(bengle.lastNativeShapingReport, isNull);
        expect(
          log.where((l) => l.contains('changed on each of 3 passes')),
          isNotEmpty,
        );
      },
    );

    List<int> roundedCliBlock({required int secondPressure}) => [
      0x02, 0x02, 0x00, 0x00, 0x00, 0x06, 0xC8, //
      secondPressure, 0x96, 0x00, 0x00, 0x00, 0x00, 0x00, //
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];

    Future<NativeShapingReport> readRoundedCli(List<int> block) async {
      final (bengle, transport) = await nsConnectBengle();
      transport.image = nsImage(source: 0, latch: 3, flags: 0x03, block: block);

      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);
      return bengle.lastNativeShapingReport!;
    }

    test('a rounded CLI report that breaks rule 8 keeps the report with no '
        'settings', () async {
      final report = await readRoundedCli(
        roundedCliBlock(secondPressure: 0x0A),
      );

      expect(report.source, NativeShapingSource.cli);
      expect(report.settingsRounded, isTrue);
      expect(report.acceptsBlockV2, isTrue);
      expect(report.settings, isNull);
    });

    test('control: the same rounded CLI report with only the pressure rise '
        'corrected decodes with settings', () async {
      final report = await readRoundedCli(
        roundedCliBlock(secondPressure: 0x0B),
      );

      expect(report.source, NativeShapingSource.cli);
      expect(report.settingsRounded, isTrue);
      expect(report.settings?.pumpCurve.map((p) => p.pressure), [0.6, 1.1]);
    });

    test('a read that times out gives no report, keeps the link and stops '
        'reg 66 reads until the next connect', () async {
      final (bengle, transport) = await nsConnectBengle();
      transport.image = null;
      final log = nsCapture('DE1');

      transport.enterState(nsEspresso);
      await nsUntil(() => transport.reportRequests.isNotEmpty);
      await nsSettle();

      expect(bengle.lastNativeShapingReport, isNull);
      expect(
        log.where((l) => l.startsWith('Native shaping report read failed')),
        hasLength(1),
      );
      expect(transport.reportRequests, hasLength(1));
      transport.image = nsImage(latch: 1);
      await bengle.setProfile(nsProfile());
      expect(transport.reportRequests, hasLength(1));
    });

    for (final (label, setUp) in [
      (
        'throws',
        (NativeShapeMachineTransport t) =>
            t.readError = StateError('link lost'),
      ),
    ]) {
      test('a read that $label gives no report and keeps the link', () async {
        final (bengle, transport) = await nsConnectBengle();
        setUp(transport);
        final log = nsCapture('DE1');

        transport.enterState(nsEspresso);
        await nsUntil(() => transport.reportRequests.length >= 2);
        await nsSettle();

        expect(bengle.lastNativeShapingReport, isNull);
        expect(
          log.where((l) => l.startsWith('Native shaping report read failed')),
          hasLength(2),
        );
        transport.readError = null;
        transport.image = nsImage(latch: 1);
        await bengle.setProfile(nsProfile());
        expect(transport.reportReads, greaterThan(0));
      });
    }

    test('a DE1 sends no reg 66 read', () async {
      final transport = NativeShapeMachineTransport();
      addTearDown(transport.dispose);
      transport.queueOnConnectResponses(v13Model: 1);
      final de1 = UnifiedDe1(
        transport: transport,
        nativeShapingReadTimings: nsTimings,
      );
      await de1.onConnect();
      transport.image = nsImage(latch: 7);

      await de1.setProfile(nsProfile());
      transport.enterState(nsEspresso);
      await nsSettle();

      expect(transport.reportRequests, isEmpty);
      expect(de1.lastNativeShapingReport, isNull);
    });
  });

  group('report life', () {
    Future<(Bengle, NativeShapeMachineTransport)> withReport() async {
      final (bengle, transport) = await nsConnectBengle();
      await nsUploadWithBaseline(bengle, transport, 7);
      transport.image = nsImage(latch: 8);
      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);
      return (bengle, transport);
    }

    test('is kept after a profile upload once espresso ends', () async {
      final (bengle, transport) = await withReport();
      final accepted = bengle.lastNativeShapingReport;
      transport.enterState(nsIdle);
      await pumpEventQueue();

      await bengle.setProfile(nsProfile(title: 'next'));

      expect(bengle.lastNativeShapingReport, accepted);
    });

    test('is kept after a raw profile write once espresso ends', () async {
      final (bengle, transport) = await withReport();
      final accepted = bengle.lastNativeShapingReport;
      transport.enterState(nsIdle);
      await pumpEventQueue();

      bengle.sendRawMessage(
        De1RawMessage(
          type: De1RawMessageType.request,
          operation: De1RawOperationType.write,
          characteristicUUID: Endpoint.headerWrite.uuid,
          payload: nsHex([1, 2, 0, 0, 0]),
        ),
      );
      await pumpEventQueue();

      expect(bengle.lastNativeShapingReport, accepted);
    });

    test('is null at the next shot start', () async {
      final (bengle, transport) = await withReport();
      transport.enterState(nsIdle);
      transport.image = null;

      transport.enterState(nsEspresso);
      await pumpEventQueue();

      expect(bengle.lastNativeShapingReport, isNull);
    });
  });

  group('baseline', () {
    test('a count equal to the baseline gives no report', () async {
      final (bengle, transport) = await nsConnectBengle();
      await nsUploadWithBaseline(bengle, transport, 7);
      final log = nsCapture('DE1');

      transport.enterState(nsEspresso);
      await nsUntil(() => transport.reportReads >= 7);
      await nsSettle();

      expect(bengle.lastNativeShapingReport, isNull);
      expect(log.where((l) => l.contains('equals the baseline')), hasLength(2));
    });

    test('a new count gives the report', () async {
      final (bengle, transport) = await nsConnectBengle();
      await nsUploadWithBaseline(bengle, transport, 7);
      transport.image = nsImage(latch: 8);

      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);

      expect(bengle.lastNativeShapingReport!.latchCount, 8);
    });

    test('an equal count at the first read and a new count at the second '
        'read gives the report', () async {
      final (bengle, transport) = await nsConnectBengle();
      await nsUploadWithBaseline(bengle, transport, 7);
      final readsBefore = transport.reportReads;
      transport.afterRead = (i) {
        if (i == readsBefore + 2) transport.image = nsImage(latch: 8);
      };

      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);

      expect(bengle.lastNativeShapingReport!.latchCount, 8);
      expect(transport.reportReads - readsBefore, 6);
    });

    test('case (a): an upload during the shot with no re-latch keeps the '
        'accepted report, and the next shot needs a new count', () async {
      final (bengle, transport) = await nsConnectBengle();
      await nsUploadWithBaseline(bengle, transport, 7);
      transport.image = nsImage(latch: 8);
      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);
      final accepted = bengle.lastNativeShapingReport;

      await bengle.setProfile(nsProfile(title: 'during the shot'));

      expect(bengle.lastNativeShapingReport, same(accepted));
      transport.enterState(nsIdle);
      transport.enterState(nsEspresso);
      await nsUntil(() => transport.reportReads >= 1 + 3 + 3 + 6);
      await nsSettle();
      expect(bengle.lastNativeShapingReport, isNull);
    });

    test('a reconnect forgets the baseline, so a restarted latch count equal '
        'to the old baseline gives the report', () async {
      final (bengle, transport) = await nsConnectBengle();
      await nsUploadWithBaseline(bengle, transport, 1);
      await bengle.onDisconnect();
      await nsConnect(bengle, transport, connectLatch: 0);
      transport.image = nsImage(latch: 1);

      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);

      expect(bengle.lastNativeShapingReport!.latchCount, 1);
    });
  });
}
