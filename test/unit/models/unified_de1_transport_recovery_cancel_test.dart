import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';

import '../../helpers/gated_ble_link.dart';

class _Rig {
  _Rig(this.link) : transport = GatedBleLink() {
    de1 = UnifiedDe1Transport(transport: overBleLink(link, transport));
  }

  final BleLinkPath link;
  final GatedBleLink transport;
  late final UnifiedDe1Transport de1;
  final states = <ConnectionState>[];
  StreamSubscription<ConnectionState>? _states;
  Object? writeError;

  Future<void> start() async {
    await de1.connect();
    await de1.subscribeBengleShotSample();
    _states = de1.connectionState.listen(states.add);
  }

  Future<void> timeoutWrite() => de1
      .write(Endpoint.requestedState, Uint8List.fromList([0x02]))
      .then<void>((_) {}, onError: (Object e) => writeError = e);

  Future<void> close() async {
    await _states?.cancel();
    if (!transport.disposed) await transport.dispose();
  }

  void expectCancelled() {
    expect(
      {
        'error': writeError.runtimeType,
        'linked': transport.linked,
        'callbacks': transport.subscribers.keys.toList(),
        'retriedWrites': requestedStateWrites(transport),
      },
      {
        'error': BleTimeoutException,
        'linked': false,
        'callbacks': isEmpty,
        'retriedWrites': 0,
      },
    );
  }
}

void main() {
  for (final link in BleLinkPath.values) {
    group(
      'explicit disconnect cancels BLE timeout recovery (${link.name})',
      () {
        late _Rig rig;

        setUp(() async {
          rig = _Rig(link);
          await rig.start();
        });

        tearDown(() => rig.close());

        test(
          'app disconnect while the recovery disconnect is pending',
          () async {
            final connects = rig.transport.connectCalls;
            final gate = rig.transport.teardownGate = Completer<void>();
            final write = rig.timeoutWrite();
            await settle();

            final disconnect = rig.de1.disconnect();
            await settle();
            gate.complete();
            await disconnect;
            await write;
            await settle();

            rig.expectCancelled();
            expect(rig.transport.connectCalls, connects);
            expect(rig.states.last, ConnectionState.disconnected);
          },
        );

        test('app disconnect while the recovery connect is pending', () async {
          final gate = rig.transport.connectGate = Completer<void>();
          final write = rig.timeoutWrite();
          await settle();

          final disconnect = rig.de1.disconnect();
          await settle();
          final gattCalls = rig.transport.gattCalls;
          gate.complete();
          await disconnect;
          await write;
          await settle();

          rig.expectCancelled();
          expect(rig.transport.gattCalls, gattCalls);
          expect(rig.states.last, ConnectionState.disconnected);
        });

        test('dispose while the recovery connect is pending', () async {
          final gate = rig.transport.connectGate = Completer<void>();
          final write = rig.timeoutWrite();
          await settle();

          final dispose = rig.de1.dispose();
          await settle();
          final gattCalls = rig.transport.gattCalls;
          gate.complete();
          await dispose;
          await write;
          await settle();

          rig.expectCancelled();
          expect(rig.transport.gattCalls, gattCalls);
        });

        test('app reconnect after a cancel keeps the new link', () async {
          final gate = rig.transport.connectGate = Completer<void>();
          final write = rig.timeoutWrite();
          await settle();

          final disconnect = rig.de1.disconnect();
          final reconnect = rig.de1.connect();
          await settle();
          gate.complete();
          await disconnect;
          await reconnect;
          await write;
          await settle();

          expect(rig.writeError, isA<BleTimeoutException>());
          expect(rig.transport.linked, isTrue);
          expect(
            rig.transport.subscribers.containsKey(Endpoint.stateInfo.uuid),
            isTrue,
          );
          expect(requestedStateWrites(rig.transport), 0);
          expect(rig.states.last, ConnectionState.connected);
        });

        test(
          'app disconnect during a restore leaves no restore request behind',
          () async {
            final gate =
                rig.transport.subscribeGates[Endpoint.bengleShotSample.uuid] =
                    Completer<void>();
            final write = rig.timeoutWrite();
            await settle();

            await rig.de1.disconnect();
            gate.complete();
            await write;
            await settle();
            rig.expectCancelled();

            await rig.de1.connect();
            final before =
                rig.transport.subscribeCounts[Endpoint.bengleShotSample.uuid];
            rig.transport.timeoutsLeft = 1;
            await rig.timeoutWrite();
            await settle();

            expect(
              rig.transport.subscribeCounts[Endpoint.bengleShotSample.uuid],
              before,
            );
            expect(
              rig.transport.subscribers.containsKey(
                Endpoint.bengleShotSample.uuid,
              ),
              isFalse,
            );
            expect(requestedStateWrites(rig.transport), 1);
          },
        );
      },
    );
  }
}
