part of 'unified_de1.dart';

class NativeShapingReadTimings {
  const NativeShapingReadTimings({
    this.firstReadDelay = const Duration(seconds: 1),
    this.retryDelay = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 1),
  });

  final Duration firstReadDelay;
  final Duration retryDelay;
  final Duration requestTimeout;
}

const _nativeShapeHalfLength = 16;
const _nativeShapeLenByte = 3;
const _nativeShapeMaxPasses = 3;
const _nativeShapeShotReads = 2;
const _espressoStateByte = 0x04;

extension UnifiedDe1NativeShaping on UnifiedDe1 {
  void _watchShotStateForNativeShaping() {
    _nativeShapingStateSubscription?.cancel();
    _lastStateByteSeen = null;
    _lastSeenLatchCount = null;
    _nativeShapingStateSubscription = _transport.state.listen(
      _onStateForNativeShaping,
      onError: (Object _) {},
    );
  }

  void _stopNativeShapingWatch() {
    _nativeShapingStateSubscription?.cancel();
    _nativeShapingStateSubscription = null;
    _lastStateByteSeen = null;
    _lastSeenLatchCount = null;
    _nativeShapingShotRunning = false;
    _nativeShapingEpoch++;
  }

  void _onStateForNativeShaping(ByteData data) {
    if (data.lengthInBytes == 0) return;
    final state = data.getUint8(0);
    final previous = _lastStateByteSeen;
    _lastStateByteSeen = state;
    final espresso = state == _espressoStateByte;
    if (!espresso) {
      _nativeShapingShotRunning = false;
      return;
    }
    if (previous == _espressoStateByte || !isBengle) return;
    _nativeShapingShotRunning = true;
    _nativeShapingReport = null;
    final epoch = ++_nativeShapingEpoch;
    unawaited(_readShotNativeShaping(epoch, _lastSeenLatchCount));
  }

  bool _isCurrentNativeShapingRead(int epoch) => epoch == _nativeShapingEpoch;

  Future<void> _readShotNativeShaping(int epoch, int? baseline) async {
    final timings = nativeShapingReadTimings;
    for (var read = 0; read < _nativeShapeShotReads; read++) {
      await Future<void>.delayed(
        read == 0 ? timings.firstReadDelay : timings.retryDelay,
      );
      if (!_isCurrentNativeShapingRead(epoch) || !_nativeShapingShotRunning) {
        return;
      }
      final report = await _queuedNativeShapingRead();
      if (!_isCurrentNativeShapingRead(epoch) || report == null) continue;
      if (baseline == null) {
        _log.info(
          'Native shaping report accepted with no baseline latch count '
          '(latch ${report.latchCount})',
        );
        _nativeShapingReport = report;
        return;
      }
      if (report.latchCount != baseline) {
        _nativeShapingReport = report;
        return;
      }
      _log.info(
        'Native shaping latch count ${report.latchCount} equals the '
        'baseline; the machine did not latch for this shot yet',
      );
    }
  }

  Future<NativeShapingReport?> _queuedNativeShapingRead() {
    final read = _profileUploadQueue.then((_) => _readNativeShapeLatched());
    _profileUploadQueue = read.then<void>((_) {}, onError: (Object _) {});
    return read;
  }

  Future<NativeShapingReport?> _readNativeShapeLatched() async {
    final timeout = nativeShapingReadTimings.requestTimeout;
    try {
      for (var pass = 0; pass < _nativeShapeMaxPasses; pass++) {
        final head = await _readNativeShapeHalf(0, timeout);
        final tail = await _readNativeShapeHalf(
          _nativeShapeHalfLength,
          timeout,
        );
        final check = await _readNativeShapeHalf(0, timeout);
        if (head[2] == check[2]) {
          _lastSeenLatchCount = head[2];
          return NativeShapingReport.fromBytes([...head, ...tail]);
        }
      }
      _log.warning(
        'Native shaping report read failed: the latch count changed on '
        'each of $_nativeShapeMaxPasses passes',
      );
    } catch (e) {
      _log.warning('Native shaping report read failed: $e');
    }
    return null;
  }

  void _readNativeShapingAtConnect() {
    final read = _profileUploadQueue.then(
      (_) =>
          _readNativeShapingBaseline(nativeShapingReadTimings.requestTimeout),
    );
    _profileUploadQueue = read.catchError((Object _) {});
  }

  Future<void> _readNativeShapingAfterUpload(Duration timeout) =>
      _nativeShapingShotRunning
      ? _readNativeShapingRelatch()
      : _readNativeShapingBaseline(timeout);

  Future<void> _readNativeShapingRelatch() async {
    final report = await _readNativeShapeLatched();
    if (report == null || !_nativeShapingShotRunning) return;
    final accepted = _nativeShapingReport;
    if (accepted == null || accepted.latchCount == report.latchCount) return;
    _log.info(
      'Native shaping re-latched after a profile upload during the shot '
      '(latch ${accepted.latchCount} to ${report.latchCount})',
    );
    _nativeShapingReport = report;
  }

  Future<void> _readNativeShapingBaseline(Duration timeout) async {
    try {
      final head = await _readNativeShapeHalf(
        0,
        timeout,
      ).timeout(timeout, onTimeout: () => const <int>[]);
      if (head.length == _nativeShapeHalfLength) _lastSeenLatchCount = head[2];
    } catch (e) {
      _log.fine('Native shaping baseline read failed: $e');
    }
  }

  Future<List<int>> _readNativeShapeHalf(int offset, Duration timeout) async {
    final reply = await _mmrReadRaw(
      MMRItem.nativeShapeLatched.address + offset,
      length: _nativeShapeLenByte,
      label: '${MMRItem.nativeShapeLatched.name}+$offset',
      timeout: timeout,
      retries: 0,
    );
    if (reply.length < 4 + _nativeShapeHalfLength) {
      throw FormatException(
        'native shaping reply has ${reply.length} bytes, needs '
        '${4 + _nativeShapeHalfLength}',
      );
    }
    return reply.sublist(4, 4 + _nativeShapeHalfLength);
  }
}
