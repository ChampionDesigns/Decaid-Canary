import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

import '../../helpers/gated_ble_link.dart';

class _RecoveryFakeTransport extends BLETransport {
  _RecoveryFakeTransport({required this.reconnectSucceeds});

  final bool reconnectSucceeds;

  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );

  int writeCount = 0;
  int connectCount = 0;
  int disconnectCount = 0;

  @override
  String get id => 'recovery-fake';

  @override
  String get name => 'RecoveryFake';

  @override
  Stream<ConnectionState> get connectionState => _connState.stream;

  @override
  Future<ConnectionState> getConnectionState() async =>
      ConnectionState.disconnected;

  @override
  Future<void> connect() async {
    connectCount++;
    if (!reconnectSucceeds) {
      throw StateError('reconnect failed');
    }
    _connState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    _connState.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => [de1ServiceUUID];

  @override
  Future<Uint8List> read(String s, String c, {Duration? timeout}) async =>
      Uint8List(20);

  @override
  Future<void> subscribe(
    String s,
    String c,
    void Function(Uint8List) cb,
  ) async {}

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> write(
    String s,
    String c,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    writeCount++;
    if (writeCount == 1) {
      throw BleTimeoutException('write');
    }
  }

  @override
  Future<void> dispose() async => _connState.close();
}

void main() {
  group('UnifiedDe1Transport timeout recovery', () {
    test('successful reconnect after timeout does not surface disconnected '
        'to upstream', () async {
      final fake = _RecoveryFakeTransport(reconnectSucceeds: true);
      addTearDown(fake.dispose);
      final unified = UnifiedDe1Transport(transport: fake);

      final seen = <ConnectionState>[];
      final sub = unified.connectionState.listen(seen.add);
      addTearDown(sub.cancel);

      await unified.write(Endpoint.requestedState, Uint8List.fromList([0x02]));
      await Future<void>.delayed(Duration.zero);

      expect(fake.disconnectCount, 1);
      expect(fake.connectCount, 1);
      expect(fake.writeCount, 2);

      expect(seen, isNot(contains(ConnectionState.disconnected)));
    });

    test(
      'failed reconnect after timeout surfaces disconnected to upstream',
      () async {
        final fake = _RecoveryFakeTransport(reconnectSucceeds: false);
        addTearDown(fake.dispose);
        final unified = UnifiedDe1Transport(transport: fake);

        final seen = <ConnectionState>[];
        final sub = unified.connectionState.listen(seen.add);
        addTearDown(sub.cancel);

        await expectLater(
          unified.write(Endpoint.requestedState, Uint8List.fromList([0x02])),
          throwsA(isA<BleTimeoutException>()),
        );
        await Future<void>.delayed(Duration.zero);

        expect(seen, contains(ConnectionState.disconnected));
      },
    );
  });

  for (final path in BleLinkPath.values) {
    test('two timeouts together start one recovery (${path.name})', () async {
      final link = GatedBleLink()..timeoutsLeft = 2;
      addTearDown(link.dispose);
      final unified = UnifiedDe1Transport(transport: overBleLink(path, link));
      await unified.connect();
      await unified.subscribeBengleShotSample();
      final connects = link.connectCalls;
      final gate = link.teardownGate = Completer<void>();

      final writes = [
        unified.write(Endpoint.requestedState, Uint8List.fromList([0x02])),
        unified.write(Endpoint.requestedState, Uint8List.fromList([0x03])),
      ];
      await settle();
      gate.complete();
      await Future.wait(writes);
      await settle();

      expect(link.connectCalls - connects, 1);
      expect(
        link.subscribeCounts.values.where((n) => n != 2).toList(),
        isEmpty,
        reason: '${link.subscribeCounts}',
      );
      expect(requestedStateWrites(link), 2);
      expect(link.linked, isTrue);
    });
  }

  for (final path in BleLinkPath.values) {
    test('a cancelled recovery does not hold or taint the app\'s new link '
        '(${path.name})', () async {
      final link = GatedBleLink()..timeoutsLeft = 1;
      addTearDown(link.dispose);
      final unified = UnifiedDe1Transport(transport: overBleLink(path, link));
      int shotSampleSubscribes() =>
          link.subscribeCounts[Endpoint.bengleShotSample.uuid] ?? 0;
      Future<void> timeoutWrite() {
        link.timeoutsLeft = 1;
        return unified.write(
          Endpoint.requestedState,
          Uint8List.fromList([0x02]),
        );
      }

      await unified.connect();
      await unified.subscribeBengleShotSample();
      final restore = link.subscribeGates[Endpoint.bengleShotSample.uuid] =
          Completer<void>();
      Object? firstError;
      final first = timeoutWrite().then<void>(
        (_) {},
        onError: (Object e) => firstError = e,
      );
      await settle();
      expect(shotSampleSubscribes(), 2);

      await unified.disconnect();
      await unified.connect();
      var secondDone = false;
      final second = timeoutWrite().then((_) => secondDone = true);
      await settle();
      expect(secondDone, isTrue);

      restore.complete();
      await first;
      await second;
      await settle();
      expect(firstError, isA<BleTimeoutException>());

      await timeoutWrite();
      await settle();

      expect(shotSampleSubscribes(), 2);
      expect(
        link.subscribers.containsKey(Endpoint.bengleShotSample.uuid),
        isFalse,
      );
      expect(requestedStateWrites(link), 2);
      expect(link.linked, isTrue);
    });
  }

  for (final path in BleLinkPath.values) {
    test('a failed recovery does not wait for a stuck teardown '
        '(${path.name})', () async {
      final link = GatedBleLink()..timeoutsLeft = 1;
      final stuck = Completer<void>();
      addTearDown(() async {
        if (!stuck.isCompleted) stuck.complete();
        await link.dispose();
      });
      final unified = UnifiedDe1Transport(transport: overBleLink(path, link));
      await unified.connect();
      final connecting = link.connectGate = Completer<void>();
      link.connectError = StateError('reconnect failed');

      final write = unified.write(
        Endpoint.requestedState,
        Uint8List.fromList([0x02]),
      );
      await settle();
      link.teardownGate = stuck;
      connecting.complete();

      await expectLater(
        write.timeout(const Duration(seconds: 2)),
        throwsA(isA<BleTimeoutException>()),
      );
    });

    test('a failed recovery still tears down, and an app connect after it '
        'keeps its link (${path.name})', () async {
      final link = GatedBleLink()..timeoutsLeft = 1;
      final stuck = Completer<void>();
      addTearDown(() async {
        if (!stuck.isCompleted) stuck.complete();
        await link.dispose();
      });
      int teardowns() => path == BleLinkPath.raw
          ? link.disconnectCalls
          : link.confirmedDisconnectCalls;
      final unified = UnifiedDe1Transport(transport: overBleLink(path, link));
      await unified.connect();
      final states = <ConnectionState>[];
      final sub = unified.connectionState.listen(states.add);
      addTearDown(sub.cancel);
      final before = teardowns();
      final connecting = link.connectGate = Completer<void>();
      link.connectError = StateError('reconnect failed');

      final write = unified.write(
        Endpoint.requestedState,
        Uint8List.fromList([0x02]),
      );
      await settle();
      link.teardownGate = stuck;
      connecting.complete();
      await expectLater(write, throwsA(isA<BleTimeoutException>()));

      link.connectError = null;
      final reconnect = unified.connect();
      await settle();
      stuck.complete();
      await reconnect;
      await settle();

      expect(teardowns(), before + 2);
      expect(link.linked, isTrue);
      expect(states.last, ConnectionState.connected);
    });
  }
}
