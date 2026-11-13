part of 'unified_de1.dart';

mixin WakeScheduleCapability on UnifiedDe1 {
  Future<void> setInactivitySleepTimeout(int minutes) async {
    await writeMmrInt(
      BengleMmr.inactivitySleepTimeout,
      minutes.clamp(0, kFirmwareMaxSleepTimeoutMinutes),
    );
  }

  Future<void> pushFirmwareWakeSchedule({
    required int secondsSinceSundayLocal,
    required List<FirmwareWakeWindow> windows,
  }) async {
    final entries = [
      for (final window in windows.take(kFirmwareMaxWakeWindows))
        firmwareStorableWakeWindow(window).pack(),
    ];
    await writeMmrInt(BengleMmr.scheduleControl, 0);
    await writeMmrInt(
      BengleMmr.setLocalTimeOfWeek,
      secondsSinceSundayLocal.clamp(0, 604799),
    );
    for (final entry in entries) {
      await writeMmrInt(BengleMmr.scheduleEntry, entry);
    }
    if (windows.isNotEmpty) {
      await writeMmrInt(BengleMmr.scheduleControl, 1);
    }
  }
}
