import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/native_shaping.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/native_shaping_reporter.dart';

import '../../helpers/native_shape_machine_transport.dart';
import '../../helpers/native_shape_report_harness.dart';

void main() {
  group('re-latch after an upload during the shot', () {
    Future<(Bengle, NativeShapeMachineTransport)> shotWithReport() async {
      final (bengle, transport) = await nsConnectBengle(connectLatch: 4);
      transport.image = nsImage(latch: 5);
      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);
      expect(bengle.lastNativeShapingReport!.latchCount, 5);
      return (bengle, transport);
    }

    test('a new count at the post-upload read replaces the report', () async {
      final (bengle, transport) = await shotWithReport();
      final log = nsCapture('DE1');
      transport.image = nsImage(latch: 6, block: nsOtherBlock);
      final readsBefore = transport.reportReads;

      await bengle.setProfile(nsProfile(title: 'during the shot'));

      expect(transport.reportReads - readsBefore, 3);
      final report = bengle.lastNativeShapingReport!;
      expect(report.latchCount, 6);
      expect(report.settings, NativeShaping.fromBlockBytes(nsOtherBlock));
      expect(log.where((l) => l.contains('re-latched')), hasLength(1));
    });

    test('the same count at the post-upload read keeps the report', () async {
      final (bengle, transport) = await shotWithReport();
      final accepted = bengle.lastNativeShapingReport;
      final readsBefore = transport.reportReads;

      await bengle.setProfile(nsProfile(title: 'during the shot'));

      expect(transport.reportReads - readsBefore, 3);
      expect(bengle.lastNativeShapingReport, same(accepted));
    });

    Future<(Bengle, NativeShapeMachineTransport)> shotWithNoLatch() async {
      final (bengle, transport) = await nsConnectBengle(connectLatch: 4);
      transport.enterState(nsEspresso);
      await nsUntil(() => transport.reportReads >= 6);
      await nsSettle();
      expect(bengle.lastNativeShapingReport, isNull);
      return (bengle, transport);
    }

    test('a new count at the post-upload read gives the report when the '
        'shot reads saw only the baseline', () async {
      final (bengle, transport) = await shotWithNoLatch();
      transport.image = nsImage(latch: 5, block: nsOtherBlock);

      await bengle.setProfile(nsProfile(title: 'during the shot'));

      final report = bengle.lastNativeShapingReport!;
      expect(report.latchCount, 5);
      expect(report.settings, NativeShaping.fromBlockBytes(nsOtherBlock));
    });

    test('the baseline count at the post-upload read gives no report when '
        'the shot reads saw only the baseline', () async {
      final (bengle, transport) = await shotWithNoLatch();
      final readsBefore = transport.reportReads;

      await bengle.setProfile(nsProfile(title: 'during the shot'));

      expect(transport.reportReads - readsBefore, 3);
      expect(bengle.lastNativeShapingReport, isNull);
    });

    test('an upload after the machine left espresso does not replace the '
        'report', () async {
      final (bengle, transport) = await shotWithReport();
      final accepted = bengle.lastNativeShapingReport;
      transport.enterState(nsIdle);
      await pumpEventQueue();
      transport.image = nsImage(latch: 6, block: nsOtherBlock);
      transport.writes.clear();

      await bengle.setProfile(nsProfile(title: 'after the shot'));

      expect(bengle.lastNativeShapingReport, same(accepted));
      expect(transport.reportRequests.map((w) => w.data[3]), [0x74]);
    });
  });

  group('connect read', () {
    test('sets the baseline: a first shot read equal to it is not accepted, '
        'a new count at the retry is', () async {
      final (bengle, transport) = await nsConnectBengle(connectLatch: 7);
      final log = nsCapture('DE1');
      transport.afterRead = (i) {
        if (i == 2) transport.image = nsImage(latch: 8);
      };

      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);

      expect(bengle.lastNativeShapingReport!.latchCount, 8);
      expect(transport.reportReads, 6);
      expect(log.where((l) => l.contains('equals the baseline')), hasLength(1));
      expect(log.where((l) => l.contains('no baseline')), isEmpty);
    });

    test('reads one head on a Bengle connect and none on a DE1', () async {
      final bengleTransport = NativeShapeMachineTransport();
      addTearDown(bengleTransport.dispose);
      bengleTransport.queuePaletteHydrationResponses();
      bengleTransport.queueOnConnectResponses(v13Model: 128);
      bengleTransport.image = nsImage(latch: 3);
      final bengle = Bengle(
        transport: bengleTransport,
        nativeShapingReadTimings: nsTimings,
      );
      addTearDown(bengle.onDisconnect);
      final de1Transport = NativeShapeMachineTransport();
      addTearDown(de1Transport.dispose);
      de1Transport.queueOnConnectResponses(v13Model: 1);
      de1Transport.image = nsImage(latch: 3);
      final de1 = UnifiedDe1(
        transport: de1Transport,
        nativeShapingReadTimings: nsTimings,
      );

      await bengle.onConnect();
      await de1.onConnect();
      await nsSettle();

      expect(bengleTransport.reportRequests.map((w) => w.data.toList()), [
        [0x03, 0x80, 0x39, 0x74, ...List.filled(16, 0)],
      ]);
      expect(de1Transport.reportRequests, isEmpty);
    });

    test('case (b): a shot that starts before the connect read ends takes the '
        'first good read and logs one line', () async {
      final transport = NativeShapeMachineTransport();
      addTearDown(transport.dispose);
      transport.queuePaletteHydrationResponses();
      transport.queueOnConnectResponses(v13Model: 128);
      final bengle = Bengle(
        transport: transport,
        nativeShapingReadTimings: nsTimings,
      );
      addTearDown(bengle.onDisconnect);
      final reply = Completer<void>();
      transport.image = nsImage(latch: 7);
      transport.replyGate = reply.future;
      final log = nsCapture('DE1');

      await bengle.onConnect();
      await nsUntil(() => transport.reportRequests.isNotEmpty);
      transport.enterState(nsEspresso);
      transport.replyGate = null;
      reply.complete();

      await nsUntil(() => nativeShapingReportedBy(bengle) != null);

      expect(bengle.lastNativeShapingReport!.latchCount, 7);
      expect(log.where((l) => l.contains('no baseline')), hasLength(1));
    });
  });

  group('read rules', () {
    test(
      'no reg 66 read runs while a profile upload writes its frames',
      () async {
        final (bengle, transport) = await nsConnectBengle(connectLatch: 4);
        transport.image = nsImage(latch: 5);
        final frames = Completer<void>();
        transport.frameWriteGate = frames.future;

        final upload = bengle.setProfile(nsProfile(title: 'held'));
        await nsUntil(
          () => transport.writes.any(
            (w) => w.characteristicUUID == Endpoint.frameWrite.uuid,
          ),
          reason: 'the first frame write',
        );
        transport.enterState(nsEspresso);
        await Future<void>.delayed(
          nsTimings.firstReadDelay + const Duration(milliseconds: 80),
        );

        expect(transport.reportRequests, isEmpty);
        transport.frameWriteGate = null;
        frames.complete();
        await upload;
        await nsUntil(() => nativeShapingReportedBy(bengle) != null);
        final tank = transport.writes.lastIndexWhere(
          (w) => w.characteristicUUID == Endpoint.writeToMMR.uuid,
        );
        final firstReport = transport.writes.indexWhere(
          (w) => transport.reportRequests.contains(w),
        );
        expect(firstReport, greaterThan(tank));
      },
    );

    test('no reg 66 read runs once the machine left espresso before the first '
        'read', () async {
      final (bengle, transport) = await nsConnectBengle(connectLatch: 4);
      transport.image = nsImage(latch: 5);

      transport.enterState(nsEspresso);
      transport.enterState(nsIdle);
      await nsSettle();

      expect(transport.reportRequests, isEmpty);
      expect(bengle.lastNativeShapingReport, isNull);
    });
  });
}
