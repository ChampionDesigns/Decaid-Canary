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
  if (window.dow < 0 ||
      window.dow > kFirmwareWakeMaxDow ||
      window.startMin < 0 ||
      window.startMin >= window.endMin ||
      window.endMin > kFirmwareWakeMaxEndMin) {
    throw UnstorableWakeWindowException(window);
  }
  return FirmwareWakeWindow(
    dow: window.dow,
    startMin: window.startMin,
    endMin: _storableEndMin(window),
  );
}

int _storableEndMin(FirmwareWakeWindow window) {
  final end = window.endMin;
  if (window.pack() < _float32ExactIntegerLimit || end.isEven) return end;
  return end + 1;
}
