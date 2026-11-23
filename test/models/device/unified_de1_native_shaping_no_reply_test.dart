import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/native_shaping_reporter.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/native_shape_machine_transport.dart';
import '../../helpers/native_shape_report_harness.dart';

const _shortReplyLength = 8;

class _ShortReplyTransport extends NativeShapeMachineTransport {
  bool shortReply = true;

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
    if (!shortReply || characteristicUUID != Endpoint.readFromMMR.uuid) return;
    final address = data[1] << 16 | data[2] << 8 | data[3];
    if (address != nativeShapeReportAddress &&
        address != nativeShapeReportAddress + 16) {
      return;
    }
    final reply = Uint8List(_shortReplyLength)..setRange(0, 4, data);
    scheduleMicrotask(() => emitNotification(Endpoint.readFromMMR, reply));
  }
}

class _FakeAsyncMachineTransport extends NativeShapeMachineTransport {
  @override
  Stream<ConnectionState> get connectionState => Stream.multi((controller) {
    controller.add(ConnectionState.connected);
    controller.close();
  });
}

Future<(Bengle, NativeShapeMachineTransport)> _connectSilentBengle() =>
    nsConnectBengle(connectLatch: null);

Future<void> _afterBothShotReads() => Future<void>.delayed(
  nsTimings.firstReadDelay +
      nsTimings.requestTimeout +
      nsTimings.retryDelay +
      nsTimings.requestTimeout +
      const Duration(milliseconds: 100),
);

bool _isTareWrite(FakeBleWrite w) =>
    w.characteristicUUID == Endpoint.writeToMMR.uuid &&
    (w.data[1] << 16 | w.data[2] << 8 | w.data[3]) ==
        BengleScaleMmr.scaleTare.address & 0xFFFFFF;

void main() {
  group('reg 66 with no reply on the link', () {
    test('after the connect read gets no reply, a shot and an upload make no '
        'reg 66 read, and one line is logged', () async {
      final log = nsCapture('DE1');
      final (bengle, transport) = await _connectSilentBengle();

      transport.enterState(nsEspresso);
      await _afterBothShotReads();
      expect(transport.reportRequests, isEmpty);

      await bengle.setProfile(nsProfile(title: 'during the shot'));
      expect(transport.reportRequests, isEmpty);

      transport.enterState(nsIdle);
      await pumpEventQueue();
      await bengle.setProfile(nsProfile(title: 'after the shot'));
      expect(transport.reportRequests, isEmpty);

      expect(bengle.lastNativeShapingReport, isNull);
      expect(
        log.where((l) => l.contains('reg 66 did not answer')),
        hasLength(1),
      );
    });

    test('a first shot read with no reply stops the second shot read and the '
        'upload read', () async {
      final (bengle, transport) = await nsConnectBengle(connectLatch: 4);
      transport.image = null;

      transport.enterState(nsEspresso);
      await _afterBothShotReads();
      expect(transport.reportRequests, hasLength(1));

      await bengle.setProfile(nsProfile(title: 'during the shot'));
      expect(transport.reportRequests, hasLength(1));
    });

    test('a reconnect reads reg 66 again and a later shot reads it', () async {
      final (bengle, transport) = await _connectSilentBengle();
      await bengle.onDisconnect();
      transport.writes.clear();

      await nsConnect(bengle, transport, connectLatch: 4);
      transport.image = nsImage(latch: 5);
      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);

      expect(bengle.lastNativeShapingReport!.latchCount, 5);
    });

    test('a no-reply timeout of the old link does not stop reg 66 reads on '
        'the new link', () async {
      const slowTimings = NativeShapingReadTimings(
        firstReadDelay: Duration(milliseconds: 20),
        retryDelay: Duration(milliseconds: 150),
        requestTimeout: Duration(milliseconds: 400),
      );
      final transport = NativeShapeMachineTransport();
      addTearDown(transport.dispose);
      final bengle = Bengle(
        transport: transport,
        nativeShapingReadTimings: slowTimings,
      );
      addTearDown(bengle.onDisconnect);
      final log = nsCapture('DE1');
      transport.queuePaletteHydrationResponses();
      transport.queueOnConnectResponses(v13Model: 128);
      await bengle.onConnect();
      await nsUntil(() => transport.reportRequests.isNotEmpty);

      await bengle.onDisconnect();
      transport.queuePaletteHydrationResponses();
      transport.queueOnConnectResponses(v13Model: 128);
      transport.image = nsImage(latch: 4);
      await bengle.onConnect();
      await Future<void>.delayed(
        slowTimings.requestTimeout + const Duration(milliseconds: 200),
      );
      expect(log.where((l) => l.contains('reg 66 did not answer')), isEmpty);

      transport.image = nsImage(latch: 5);
      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);
      expect(bengle.lastNativeShapingReport!.latchCount, 5);
    });

    test('a reconnect sends one connect read for 0x00803974', () async {
      final (bengle, transport) = await _connectSilentBengle();
      await bengle.onDisconnect();
      transport.writes.clear();

      transport.queuePaletteHydrationResponses();
      transport.queueOnConnectResponses(v13Model: 128);
      await bengle.onConnect();
      await nsUntil(() => transport.reportRequests.isNotEmpty);
      await Future<void>.delayed(
        nsTimings.requestTimeout + const Duration(milliseconds: 50),
      );

      expect(transport.reportRequests.map((w) => w.data.toList()), [
        [0x03, 0x80, 0x39, 0x74, ...List.filled(16, 0)],
      ]);
    });

    test('a short reply does not stop reg 66 reads: the next shot reads '
        'reg 66', () async {
      final transport = _ShortReplyTransport();
      addTearDown(transport.dispose);
      final bengle = Bengle(
        transport: transport,
        nativeShapingReadTimings: nsTimings,
      );
      addTearDown(bengle.onDisconnect);
      final log = nsCapture('DE1');
      await nsConnect(bengle, transport, connectLatch: null);

      transport.enterState(nsEspresso);
      await nsUntil(() => transport.reportRequests.length >= 2);
      await _afterBothShotReads();

      expect(transport.reportRequests, hasLength(2));
      expect(log.where((l) => l.contains('reg 66 did not answer')), isEmpty);

      transport.shortReply = false;
      transport.image = nsImage(latch: 5);
      transport.enterState(nsIdle);
      transport.enterState(nsEspresso);
      await nsUntil(() => nativeShapingReportedBy(bengle) != null);
      expect(bengle.lastNativeShapingReport!.latchCount, 5);
    });

    test('a pour tare at espresso entry + 1.2 s is written before entry + '
        '1.3 s', () {
      fakeAsync((async) {
        final transport = _FakeAsyncMachineTransport();
        transport.queuePaletteHydrationResponses();
        transport.queueOnConnectResponses(v13Model: 128);
        final bengle = Bengle(transport: transport);

        unawaited(bengle.onConnect());
        async.elapse(const Duration(seconds: 5));
        expect(transport.reportRequests, hasLength(1));
        transport.writes.clear();

        transport.enterState(nsEspresso);
        async.elapse(const Duration(milliseconds: 1200));
        unawaited(bengle.tareIntegratedScale());
        async.elapse(const Duration(milliseconds: 99));

        expect(transport.writes.where(_isTareWrite), hasLength(1));
        expect(transport.reportRequests, isEmpty);

        async.elapse(const Duration(seconds: 10));
        expect(transport.reportRequests, isEmpty);
        unawaited(bengle.onDisconnect());
        transport.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
