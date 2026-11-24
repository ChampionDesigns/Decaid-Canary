part of 'unified_de1.dart';

/// Bengle firmware (BLE protocol v2) supports flow rates up to 20 ml/s,
/// versus the DE1's 8 ml/s. de1plus raises `max_flowrate` to 20 when
/// `use_ble_v2` is negotiated (`de1_de1.tcl:778-782`). reaprime is headless
/// — there is no UI slider to bound a flow input — so the profile encoder
/// is the enforcement point for this ceiling.
const double _bengleMaxFlowMlPerSec = 20.0;

const double _maxStepTemperature = 127.5;
const int _maxStepVolume = 1023;
const double _maxPowerExitWatts = 25.5;
const _nativeShapingSlots = [21, 22, 23, 24];
const _nativeShapingSlotLength = 7;
const _maxProfileSteps = 20;

class ProfileValueUnsupportedException extends ProfileModeUnsupportedException
    implements UnsupportedError {
  ProfileValueUnsupportedException({
    required this.field,
    required this.value,
    required String problem,
    this.stepNumber,
    String? stepName,
    required String profileTitle,
  }) : super(
         'Profile "$profileTitle"'
         '${stepNumber == null ? '' : ' step $stepNumber ("$stepName")'}: '
         '$field $value $problem',
       );

  final int? stepNumber;
  final String field;
  final double value;

  @override
  StackTrace? get stackTrace => null;
}

extension UnifiedDe1Profile on UnifiedDe1 {
  Future<void> _sendProfile(Profile profile) async {
    _assertProfileEncodable(profile);
    _lastTailDe1Emulation = false;
    final rawProfileWrites = _rawProfileWrites;
    await _writeHeader(profile);
    await _writeSteps(profile);
    final tailDe1Emulation = profile.usesDe1Emulation(
      machineSupported: implementation == .bengle,
    );
    await _writeNativeShapingBlock(profile, tailDe1Emulation);
    await _writeTail(profile, tailDe1Emulation);
    if (rawProfileWrites == _rawProfileWrites) {
      _lastTailDe1Emulation = tailDe1Emulation;
    }
    await _writeMMRInt(MMRItem.tankTemp, profile.tankTemperature.round());
  }

  /// Encode a flow (ml/s) or pressure (bar) profile field to its wire byte,
  /// honouring the negotiated protocol version.
  ///
  /// A Bengle decodes these as **U8D1** (`byte × 0.1`, range 0..25.5); a DE1
  /// uses **U8P4** (`byte / 16`, range 0..15.9375). Encoding a v2 value with
  /// the v1 scale silently mis-commands the machine (`6 ml/s` written as the
  /// v1 `96` reads back as `9.6` on a Bengle). Both paths saturate at the ends
  /// of their range. Mirrors de1plus `convert_float_to_flow_pressure_byte`
  /// (`binary.tcl`).
  int _encodeFlowPressure(double value) => isBengle
      ? Helper.convert_float_to_U8D1(value)
      : Helper.convert_float_to_U8P4(value);

  int _encodeLimiterByte(double value) => isBengle
      ? Helper.convert_float_to_U8D1(value)
      : Helper.convert_float_to_U8P4(value);

  /// True iff [step] is a HOLD step that carries an ext HOLD Mode byte (3/4/5).
  /// Pressure/flow/power steps honour `transition:hold`; a LEVER step never
  /// does (the editor forces JUMP on lever), so a `hold` marker on a lever step
  /// is treated as a plain lever (Mode 2), NOT HOLD.
  bool _isHoldStep(ProfileStep step) =>
      step.transition == TransitionType.hold && step is! ProfileStepLever;

  void _assertProfileEncodable(Profile profile) {
    if (profile.steps.length > _maxProfileSteps) {
      throw ProfileModeUnsupportedException(
        'Profile "${profile.title}" has ${profile.steps.length} steps; the '
        'machine runs at most $_maxProfileSteps steps.',
      );
    }
    void refuse(String field, double value, String problem, [int? step]) =>
        throw ProfileValueUnsupportedException(
          field: field,
          value: value,
          problem: problem,
          stepNumber: step == null ? null : step + 1,
          stepName: step == null ? null : profile.steps[step].name,
          profileTitle: profile.title,
        );
    void requireNumber(String field, double value, [int? step]) {
      if (value.isNaN) refuse(field, value, 'is not a number', step);
    }

    void requireNotNegative(String field, double value, int step) {
      requireNumber(field, value, step);
      if (value < 0) refuse(field, value, 'is below 0', step);
    }

    void requirePressureCap(double value, int step) {
      if (!value.isFinite) {
        refuse('limiter value', value, 'is not a finite number', step);
      }
      if (_encodeFlowPressure(value) == 0) {
        refuse('limiter value', value, 'encodes to a pressure cap of 0', step);
      }
    }

    for (var i = 0; i < profile.steps.length; i++) {
      final step = profile.steps[i];
      final temperature = step.temperature;
      if (!(temperature >= 0 && temperature <= _maxStepTemperature)) {
        refuse(
          'temperature',
          temperature,
          'is outside 0 to $_maxStepTemperature C',
          i,
        );
      }
      if (!_isHoldStep(step)) {
        requireNumber(_targetField(step), step.getTarget(), i);
      }
      requireNotNegative('seconds', step.seconds, i);
      requireNumber('exit value', step.exit?.value ?? 0, i);
      final exit = step.exit;
      if (exit != null && exit.type == ExitType.power) {
        final watts = exit.value;
        if (!(watts >= 0 && watts <= _maxPowerExitWatts)) {
          refuse(
            'power exit value',
            watts,
            'is outside 0 to $_maxPowerExitWatts W',
            i,
          );
        }
      }
      requireNotNegative('volume', step.volume, i);
      if (step.volume > _maxStepVolume) {
        refuse('volume', step.volume, 'is above $_maxStepVolume ml', i);
      }
      final limiter = step.limiter;
      if (step is ProfileStepPower) {
        requirePressureCap(limiter?.value ?? 0, i);
      } else if (limiter != null && limiter.value != 0) {
        requireNumber('limiter value', limiter.value, i);
        requireNumber('limiter range', limiter.range, i);
      }
      if (step is ProfileStepLever) {
        requireNumber('lever spring', step.leverSpring, i);
        requireNumber('lever give', step.leverGive, i);
      }
    }
    if (!profile.tankTemperature.isFinite) {
      refuse('tank temperature', profile.tankTemperature, 'cannot be encoded');
    }
  }

  String _targetField(ProfileStep step) => switch (step) {
    ProfileStepFlow() => 'flow',
    ProfileStepPower() => 'power',
    _ => 'pressure',
  };

  Future<void> _writeHeader(Profile profile) async {
    final scale = isBengle ? 10.0 : 16.0;

    Uint8List data = Uint8List(5);

    int index = 0;
    data[index] = isBengle ? 2 : 1;
    index++;
    data[index] = profile.steps.length;
    index++;
    data[index] = profile.targetVolumeCountStart;
    index++;
    data[index] = 0;
    index++;
    data[index] = (0.5 + 12.0 * scale).toInt();

    await _transport.writeWithResponse(Endpoint.headerWrite, data);
  }

  Future<void> _writeSteps(Profile profile) async {
    final scale = isBengle ? 10.0 : 16.0;

    for (var i = 0; i < profile.steps.length; i++) {
      var step = profile.steps[i];
      _log.fine("encoding step ${step.name}");
      _log.fine("limiter: ${step.limiter?.toJson()}");
      _log.fine("exit: ${step.exit?.toJson()}");
      Uint8List data = Uint8List(8);

      int index = 0;
      data[index] = i;
      index++;
      data[index] = Helper.convertProfileFlags(step);
      index++;
      double setVal = step.getTarget();
      if (_isHoldStep(step)) {
        setVal = 0.0;
      }
      if (isBengle &&
          step is ProfileStepFlow &&
          setVal > _bengleMaxFlowMlPerSec) {
        setVal = _bengleMaxFlowMlPerSec;
      }
      data[index] = _encodeFlowPressure(setVal);
      index++;
      data[index] = (0.5 + step.temperature * 2.0).toInt();
      index++;
      data[index] = Helper.convert_float_to_F8_1_7(step.seconds);
      index++;
      data[index] = Helper.saturatingByte(step.exit?.value ?? 0, scale);
      index++;
      Helper.convert_float_to_U10P0(step.volume, data, index);

      await _transport.writeWithResponse(Endpoint.frameWrite, data);
    }

    for (var i = 0; i < profile.steps.length; i++) {
      var step = profile.steps[i];
      int stepIndex = 32 + i;
      Uint8List data = Uint8List(8);

      data[0] = stepIndex;

      if (_isHoldStep(step)) {
        if (!isBengle) {
          throw StateError(
            'The HOLD transition requires Bengle firmware (protocol v2); '
            'refusing to encode step "${step.name}" for a DE1.',
          );
        }
        if (step is ProfileStepPressure) {
          final limiter = step.limiter;
          final hasFlowCap = limiter != null && limiter.value != 0;
          data[1] = hasFlowCap ? _encodeFlowPressure(limiter.value) : 0;
          data[2] = hasFlowCap ? _encodeFlowPressure(limiter.range) : 0;
          data[3] = 3; // Mode = HOLD-pressure
          data[4] = 0;
          data[5] = 0;
          data[6] = 0;
          data[7] = 0;
        } else if (step is ProfileStepFlow) {
          final limiter = step.limiter;
          final hasPressureCap = limiter != null && limiter.value != 0;
          data[1] = hasPressureCap ? _encodeFlowPressure(limiter.value) : 0;
          data[2] = hasPressureCap ? _encodeFlowPressure(limiter.range) : 0;
          data[3] = 4; // Mode = HOLD-flow
          data[4] = 0;
          data[5] = 0;
          data[6] = 0;
          data[7] = 0;
        } else if (step is ProfileStepPower) {
          final limiter = step.limiter;
          if (limiter == null || limiter.value == 0) {
            throw StateError(
              'HOLD power step "${step.name}" requires a pressure limiter',
            );
          }
          data[1] = 0;
          data[2] = 0;
          data[3] = 5; // Mode = HOLD-power
          data[4] = _encodeFlowPressure(limiter.value); // ModeMaxP cap
          data[5] = 0;
          data[6] = 0;
          data[7] = 0;
        }

        await _transport.writeWithResponse(Endpoint.frameWrite, data);
        continue;
      }

      if (step is ProfileStepPower || step is ProfileStepLever) {
        if (!isBengle) {
          throw StateError(
            'Power/Lever pump modes require Bengle firmware (protocol v2); '
            'refusing to encode step "${step.name}" for a DE1.',
          );
        }
        if (step is ProfileStepPower) {
          final limiter = step.limiter;
          if (limiter == null || limiter.value == 0) {
            throw StateError(
              'power step "${step.name}" requires a pressure limiter',
            );
          }
          data[1] = 0;
          data[2] = 0;
          data[3] = 1; // Mode = Power
          data[4] = _encodeFlowPressure(limiter.value); // ModeMaxP = cap
          data[5] = 0; // LeverSpring n/a
          data[6] = 0; // LeverGive n/a
          data[7] = 0;
        } else if (step is ProfileStepLever) {
          final limiter = step.limiter;
          final hasFlowCap = limiter != null && limiter.value != 0;
          data[1] = hasFlowCap ? _encodeFlowPressure(limiter.value) : 0;
          data[2] = hasFlowCap ? _encodeFlowPressure(limiter.range) : 0;
          data[3] = 2; // Mode = Lever
          data[4] = _encodeFlowPressure(step.getTarget());
          data[5] = Helper.convert_float_to_U8D1(step.leverSpring);
          data[6] = Helper.convert_float_to_U8D1(step.leverGive);
          data[7] = 0;
        }

        await _transport.writeWithResponse(Endpoint.frameWrite, data);
        continue;
      }

      if (step.limiter == null || step.limiter?.value == 0) {
        continue;
      }
      double limiterValue = step.limiter!.value;
      double limiterRange = step.limiter!.range;

      data[1] = _encodeLimiterByte(limiterValue);
      data[2] = _encodeLimiterByte(limiterRange);

      data[3] = 0;
      data[4] = 0;
      data[5] = 0;
      data[6] = 0;
      data[7] = 0;

      await _transport.writeWithResponse(Endpoint.frameWrite, data);
    }
  }

  Future<void> _writeNativeShapingBlock(
    Profile profile,
    bool tailDe1Emulation,
  ) async {
    final shaping = profile.nativeShaping;
    if (!isBengle || shaping == null || tailDe1Emulation) return;
    final block = shaping.toBlockBytes();
    final slotCount = block.length ~/ _nativeShapingSlotLength;
    for (final (i, slot) in _nativeShapingSlots.take(slotCount).indexed) {
      final data = Uint8List(8);
      data[0] = slot;
      data.setRange(1, 8, block, i * _nativeShapingSlotLength);
      await _transport.writeWithResponse(Endpoint.frameWrite, data);
    }
  }

  Future<void> _writeTail(Profile profile, bool de1Emulation) async {
    Uint8List data = Uint8List(8);

    data[0] = profile.steps.length;

    data[3] = de1Emulation ? 1 : 0;
    data[4] = 0;
    data[5] = 0;
    data[6] = 0;
    data[7] = 0;
    await _transport.writeWithResponse(Endpoint.frameWrite, data);
  }
}

class Helper {
  // ignore: non_constant_identifier_names
  static double convert_F8_1_7_to_float(int x) {
    if ((x & 128) == 0) {
      return x / 10.0;
    } else {
      return (x & 127).toDouble();
    }
  }

  /// U8D1: unsigned byte, scale ×0.1 (range 0..25.5, step 0.1) — the Bengle
  /// (BLE protocol v2) flow/pressure encoding. Clamps to the byte range so
  /// out-of-range values saturate instead of wrapping. Uses round-half-up (to
  /// match the `+ 0.5` truncation the v1 path uses). Mirrors de1plus
  /// `convert_float_to_U8D1` (`binary.tcl`).
  // ignore: non_constant_identifier_names
  static int convert_float_to_U8D1(double x) {
    final clamped = x < 0.0 ? 0.0 : (x > 25.5 ? 25.5 : x);
    return (clamped * 10).round();
  }

  static int saturatingByte(double x, double scale) {
    final top = 255 / scale;
    final clamped = x < 0.0 ? 0.0 : (x > top ? top : x);
    return (0.5 + clamped * scale).toInt();
  }

  // ignore: non_constant_identifier_names
  static int convert_float_to_U8P4(double x) {
    final clamped = x < 0.0 ? 0.0 : (x > 15.9375 ? 15.9375 : x);
    return (0.5 + clamped * 16.0).toInt();
  }

  // ignore: non_constant_identifier_names
  static int convert_float_to_F8_1_7(double x) {
    if (x == 0) {
      return 0;
    }
    var ret = 0;
    if (x >= 12.75) {
      if (x > 127) {
        ret = (127 | 0x80);
      } else {
        ret = (0x80 | (0.5 + x).toInt());
      }
    } else {
      ret = (0.5 + x * 10).toInt();
    }
    return ret;
  }

  // ignore: non_constant_identifier_names
  static void convert_float_to_U10P0_for_tail(
    double maxTotalVolume,
    Uint8List data,
    int index,
  ) {
    if (maxTotalVolume == 0) {
      return;
    }
    int ix = maxTotalVolume.toInt();

    if (ix > 1023) {
      ix = 1023;
    }
    data[index] = ix >> 8;
    data[index + 1] = (ix & 0xff);
  }

  // ignore: non_constant_identifier_names
  static double convert_bottom_10_of_U10P0(int x) {
    return (x & 1023).toDouble();
  }

  // ignore: non_constant_identifier_names
  static void convert_float_to_U10P0(double x, Uint8List data, int index) {
    Uint8List d = Uint8List(2);

    int ix = x.toInt() | 1024;
    d.buffer.asByteData().setInt16(0, ix);

    data[index] = d.buffer.asByteData().getUint8(0);
    data[index + 1] = d.buffer.asByteData().getUint8(1);
  }

  static int ctrlF = 0x01;
  // ignore: constant_identifier_names
  static int doCompare = 0x02;
  // ignore: constant_identifier_names
  static int dcGT = 0x04;
  // ignore: constant_identifier_names
  static int dcCompF = 0x08;
  // ignore: constant_identifier_names
  static int tMixTemp = 0x10;
  // ignore: constant_identifier_names
  static int interpolate = 0x20;
  // ignore: constant_identifier_names
  static int ignoreLimit = 0x40;
  // ignore: constant_identifier_names
  static int comparePower =
      0x80; // Exit when measured hydraulic power (0.1*P*F) crosses TriggerVal

  static int convertProfileFlags(ProfileStep step) {
    int flag = ignoreLimit;

    if (step is ProfileStepFlow) flag |= ctrlF;
    if (step.sensor == TemperatureSensor.water) flag |= tMixTemp;
    if (step.transition == TransitionType.smooth) flag |= interpolate;

    if (step.exit != null) {
      if (step.exit!.type == ExitType.power) {
        flag |= comparePower;
        if (step.exit!.condition == ExitCondition.over) flag |= dcGT;
      } else {
        flag |= doCompare;
        if (step.exit!.type == ExitType.flow) flag |= dcCompF;
        if (step.exit!.condition == ExitCondition.over) flag |= dcGT;
      }
    }

    return flag;
  }
}
