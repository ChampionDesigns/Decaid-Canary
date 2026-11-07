import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_est_sample.dart'
    show bengleEstSampleBytes;
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';

import '../../helpers/fake_ble_transport.dart';

class _DroppingTimeoutTransport extends FakeBleTransport {
  bool _timedOut = false;
  int estimatorSubscribes = 0;

  @override
  Future<void> disconnect() async {
    await super.disconnect();
    subscribers.clear();
  }

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    if (characteristicUUID == Endpoint.estimator.uuid) estimatorSubscribes++;
    await super.subscribe(serviceUUID, characteristicUUID, callback);
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (!_timedOut) {
      _timedOut = true;
      throw BleTimeoutException('write');
    }
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }
}

List<int> _sample(int fill) => List<int>.filled(bengleEstSampleBytes, fill);

int _requestedStateWrites(FakeBleTransport t) => t.writes
    .where((w) => w.characteristicUUID == Endpoint.requestedState.uuid)
    .length;

Future<void> _timeoutWrite(UnifiedDe1Transport de1) async {
  await de1.write(Endpoint.requestedState, Uint8List.fromList([0x02]));
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('estimator after BLE timeout recovery', () {
    late _DroppingTimeoutTransport transport;
    late UnifiedDe1Transport de1;
    late List<ByteData> samples;
    late StreamSubscription<ByteData> sub;

    setUp(() async {
      transport = _DroppingTimeoutTransport()
        ..presentCharacteristics = [Endpoint.estimator.uuid];
      de1 = UnifiedDe1Transport(transport: transport);
      samples = [];
      sub = de1.estimator
          .where((d) => d.lengthInBytes >= bengleEstSampleBytes)
          .listen(samples.add);
      await de1.connect();
    });

    tearDown(() async {
      await sub.cancel();
      await transport.dispose();
    });

    test('streams again when the machine still offers A014', () async {
      expect(await de1.subscribeEstimator(), isTrue);
      transport.emitNotification(Endpoint.estimator, _sample(1));
      await Future<void>.delayed(Duration.zero);
      expect(samples, hasLength(1));

      await _timeoutWrite(de1);
      expect(transport.disconnectCalls, 1);

      transport.emitNotification(Endpoint.estimator, _sample(2));
      await Future<void>.delayed(Duration.zero);

      expect(samples, hasLength(2));
      expect(samples.last.getUint8(0), 2);
      expect(transport.estimatorSubscribes, 2);
      expect(_requestedStateWrites(transport), 1);
    });

    test(
      'skips A014 when it is gone after recovery and retries the write',
      () async {
        expect(await de1.subscribeEstimator(), isTrue);
        transport.presentCharacteristics = const [];

        await _timeoutWrite(de1);

        expect(transport.disconnectCalls, 1);
        expect(transport.estimatorSubscribes, 1);
        expect(
          transport.subscribers.containsKey(Endpoint.estimator.uuid),
          isFalse,
        );
        expect(_requestedStateWrites(transport), 1);
      },
    );

    test('a full disconnect clears the estimator request', () async {
      expect(await de1.subscribeEstimator(), isTrue);
      await de1.disconnect();
      await de1.connect();

      await _timeoutWrite(de1);

      expect(transport.disconnectCalls, 2);
      expect(transport.estimatorSubscribes, 1);
      expect(
        transport.subscribers.containsKey(Endpoint.estimator.uuid),
        isFalse,
      );
      expect(_requestedStateWrites(transport), 1);
    });

    test(
      'does not subscribe A014 when the estimator was never requested',
      () async {
        await _timeoutWrite(de1);

        expect(transport.disconnectCalls, 1);
        expect(transport.estimatorSubscribes, 0);
        expect(
          transport.subscribers.containsKey(Endpoint.estimator.uuid),
          isFalse,
        );
        expect(_requestedStateWrites(transport), 1);
      },
    );
  });
}
