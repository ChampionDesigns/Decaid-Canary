import 'package:reaprime/src/models/firmware_wake_window.dart';

const int kFirmwareWakeMaxDow = 6;

const int kFirmwareWakeMaxEndMin = 1440;

const int _float32ExactIntegerLimit = 1 << 24;

class UnstorableWakeWindowException implements Exception {
  const UnstorableWakeWindowException(this.window);

  final FirmwareWakeWindow window;

  @override
  String toString() =>
      'UnstorableWakeWindowException: the firmware cannot store $window';
}

FirmwareWakeWindow firmwareStorableWakeWindow(FirmwareWakeWindow window) {
  final sent = FirmwareWakeWindow(
    dow: window.dow,
    startMin: window.startMin,
    endMin: _storableEndMin(window),
  );
  if (sent.dow < 0 ||
      sent.dow > kFirmwareWakeMaxDow ||
      sent.startMin < 0 ||
      sent.startMin >= sent.endMin ||
      sent.endMin > kFirmwareWakeMaxEndMin) {
    throw UnstorableWakeWindowException(window);
  }
  return sent;
}

int _storableEndMin(FirmwareWakeWindow window) {
  final end = window.endMin;
  if (window.pack() < _float32ExactIntegerLimit || end.isEven) return end;
  return end + 1 <= kFirmwareWakeMaxEndMin ? end + 1 : end - 1;
}
