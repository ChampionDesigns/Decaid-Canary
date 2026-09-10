part of 'unified_de1.dart';

int _toFirmwareRgb(Color16 color) =>
    ((color.red >> 8) << 16) | ((color.green >> 8) << 8) | (color.blue >> 8);

mixin LedStripCapability on UnifiedDe1 {
  BehaviorSubject<LedStripState?> _ledStripState =
      BehaviorSubject<LedStripState?>.seeded(null);

  Stream<LedStripState?> get ledStripState => _ledStripState.stream;

  Future<LedStripState?> getLedStripState() => _ledStripState.first;

  Future<void> setLedStrip(LedStripState state) async {
    final stored = state.canonical();
    try {
      await writeMmrInt(
        BengleMmr.frontLedAwake,
        _toFirmwareRgb(stored.frontStrip.awake),
      );
      await writeMmrInt(
        BengleMmr.frontLedSleep,
        _toFirmwareRgb(stored.frontStrip.sleeping),
      );
      await writeMmrInt(
        BengleMmr.rearLedAwake,
        _toFirmwareRgb(stored.backStrip.awake),
      );
      await writeMmrInt(
        BengleMmr.rearLedSleep,
        _toFirmwareRgb(stored.backStrip.sleeping),
      );
    } catch (e) {
      if (!_ledStripState.isClosed) {
        _ledStripState.add(null);
      }
      rethrow;
    }
    if (!_ledStripState.isClosed) {
      _ledStripState.add(stored);
    }
  }

  Future<void> commitLedStrip() async {}

  Future<LedStripState?> resetLedStrip() async {
    if (await _hydrateLedStrip()) {
      return _ledStripState.value;
    }
    return null;
  }

  Future<void> initLedStrip() async {
    if (_ledStripState.isClosed) {
      _ledStripState = BehaviorSubject<LedStripState?>.seeded(null);
    }
    await _hydrateLedStrip();
  }

  Future<bool> _hydrateLedStrip() async {
    try {
      final frontAwake = await readMmrInt(BengleMmr.frontLedAwake);
      final frontSleep = await readMmrInt(BengleMmr.frontLedSleep);
      final rearAwake = await readMmrInt(BengleMmr.rearLedAwake);
      final rearSleep = await readMmrInt(BengleMmr.rearLedSleep);
      final state = LedStripState(
        frontStrip: ZoneLedState(
          awake: Color16.fromFirmwareRgb(frontAwake),
          sleeping: Color16.fromFirmwareRgb(frontSleep),
        ),
        backStrip: ZoneLedState(
          awake: Color16.fromFirmwareRgb(rearAwake),
          sleeping: Color16.fromFirmwareRgb(rearSleep),
        ),
      ).canonical();
      if (!_ledStripState.isClosed) {
        _ledStripState.add(state);
      }
      return true;
    } catch (e) {
      this.log.warning('LedStripCapability: palette hydration failed: $e');
      if (!_ledStripState.isClosed) {
        _ledStripState.add(null);
      }
      return false;
    }
  }

  Future<void> disposeLedStrip() async {
    if (!_ledStripState.isClosed) {
      await _ledStripState.close();
    }
  }
}
