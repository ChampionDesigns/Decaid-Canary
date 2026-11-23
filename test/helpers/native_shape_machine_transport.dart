import 'dart:async';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';

import 'fake_ble_transport.dart';

const nativeShapeReportAddress = 0x00803974;
const espressoStateByte = 0x04;
const idleStateByte = 0x02;

const exampleNativeShapingBlock = [
  0x01, 0x05, 0x19, 0x19, 0x32, 0x0A, 0xC8, //
  0x1E, 0x78, 0x3C, 0x3C, 0x5A, 0x32, 0x78, //
  0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

List<int> nativeShapeReportImage({
  int source = 1,
  int rule = 0,
  required int latch,
  int flags = 0,
  List<int> block = exampleNativeShapingBlock,
}) => [source, rule, latch, flags, ...block, 0, 0, 0, 0, 0, 0, 0];

class NativeShapeMachineTransport extends FakeBleTransport {
  List<int>? image;
  Object? readError;
  void Function(int readIndex)? afterRead;
  int reportReads = 0;
  Future<void>? replyGate;
  Future<void>? frameWriteGate;

  bool _isReportRead(String uuid, Uint8List data) {
    if (uuid != Endpoint.readFromMMR.uuid || data.length < 4) return false;
    final address = data[1] << 16 | data[2] << 8 | data[3];
    return address == nativeShapeReportAddress ||
        address == nativeShapeReportAddress + 16;
  }

  List<FakeBleWrite> get reportRequests =>
      writes.where((w) => _isReportRead(w.characteristicUUID, w.data)).toList();

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
    final frameGate = frameWriteGate;
    if (frameGate != null && characteristicUUID == Endpoint.frameWrite.uuid) {
      await frameGate;
    }
    if (!_isReportRead(characteristicUUID, data)) return;
    final error = readError;
    if (error != null) throw error;
    final current = image;
    final readIndex = reportReads++;
    if (current != null) {
      final offset =
          (data[1] << 16 | data[2] << 8 | data[3]) - nativeShapeReportAddress;
      final reply = Uint8List(20)
        ..setRange(0, 4, data)
        ..setRange(4, 20, current, offset);
      final gate = replyGate;
      if (gate == null) {
        scheduleMicrotask(() => emitNotification(Endpoint.readFromMMR, reply));
      } else {
        unawaited(
          gate.then((_) => emitNotification(Endpoint.readFromMMR, reply)),
        );
      }
    }
    afterRead?.call(readIndex);
  }

  void enterState(int state) =>
      emitNotification(Endpoint.stateInfo, [state, 0]);
}
