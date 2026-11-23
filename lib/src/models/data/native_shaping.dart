import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

enum NativeShapingMode {
  both(0),
  rise(1),
  fall(2);

  const NativeShapingMode(this.code);

  final int code;

  static NativeShapingMode parse(Object? value, String field) {
    if (value == null) return NativeShapingMode.both;
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    throw ArgumentError(
      'native_shaping "$field" must be one of both, rise, fall',
    );
  }

  static NativeShapingMode? fromCode(int code) {
    for (final mode in values) {
      if (mode.code == code) return mode;
    }
    return null;
  }
}

@immutable
class PumpCurvePoint extends Equatable {
  final double pressure;
  final double flow;

  const PumpCurvePoint._(this.pressure, this.flow);

  Map<String, dynamic> toJson() => {'pressure': pressure, 'flow': flow};

  @override
  List<Object?> get props => [pressure, flow];
}

@immutable
class NativeShaping extends Equatable {
  static const supportedVersion = 1;
  static const maxPumpCurvePoints = 8;
  static const blockLength = 21;

  static const _tauDivisor = 50.0;
  static const _rampDivisor = 50.0;
  static const _pointDivisor = 10.0;
  static const _maxTauByte = 250;
  static const _maxRampByte = 200;
  static const _minPressureByte = 5;
  static const _maxPressureByte = 135;
  static const _minPressureRiseBytes = 5;
  static const _maxFlowByte = 200;

  final int version;
  final List<PumpCurvePoint> pumpCurve;
  final double flowTau;
  final NativeShapingMode flowMode;
  final double pressureTau;
  final NativeShapingMode pressureMode;
  final double rampFactor;

  const NativeShaping._({
    required this.version,
    required this.pumpCurve,
    required this.flowTau,
    required this.flowMode,
    required this.pressureTau,
    required this.pressureMode,
    required this.rampFactor,
  });

  factory NativeShaping.fromJson(Map<String, dynamic> json) {
    final version = _parseVersion(json['version']);
    final rawCurve = json['pump_curve'] ?? const [];
    if (rawCurve is! List) {
      throw ArgumentError('native_shaping "pump_curve" must be an array');
    }
    if (rawCurve.length > maxPumpCurvePoints) {
      throw ArgumentError(
        'native_shaping "pump_curve" must have 0-$maxPumpCurvePoints points',
      );
    }
    final pressureBytes = <int>[];
    final flowBytes = <int>[];
    for (final (index, rawPoint) in rawCurve.indexed) {
      if (rawPoint is! Map) {
        throw ArgumentError(
          'native_shaping "pump_curve[$index]" must be an object',
        );
      }
      pressureBytes.add(
        _wireByte(
          rawPoint['pressure'],
          'pump_curve[$index].pressure',
          _pointDivisor,
          required: true,
        ),
      );
      flowBytes.add(
        _wireByte(
          rawPoint['flow'],
          'pump_curve[$index].flow',
          _pointDivisor,
          required: true,
        ),
      );
    }
    return _checked(
      version: version,
      pressureBytes: pressureBytes,
      flowBytes: flowBytes,
      flowTauByte: _wireByte(json['flow_tau'], 'flow_tau', _tauDivisor),
      flowMode: NativeShapingMode.parse(json['flow_mode'], 'flow_mode'),
      pressureTauByte: _wireByte(
        json['pressure_tau'],
        'pressure_tau',
        _tauDivisor,
      ),
      pressureMode: NativeShapingMode.parse(
        json['pressure_mode'],
        'pressure_mode',
      ),
      rampByte: _wireByte(
        json['ramp_factor'],
        'ramp_factor',
        _rampDivisor,
        absent: 1,
      ),
    );
  }

  factory NativeShaping.fromBlockBytes(List<int> bytes) {
    if (bytes.length != blockLength) {
      throw ArgumentError(
        'native_shaping block must be $blockLength bytes, got ${bytes.length}',
      );
    }
    if (bytes[0] != supportedVersion) {
      throw ArgumentError(
        'native_shaping block version ${bytes[0]} is not supported',
      );
    }
    final flowMode = NativeShapingMode.fromCode(bytes[1] >> 6 & 0x3);
    final pressureMode = NativeShapingMode.fromCode(bytes[1] >> 4 & 0x3);
    if (flowMode == null || pressureMode == null) {
      throw ArgumentError('native_shaping block has an unknown mode code');
    }
    final count = bytes[1] & 0xF;
    if (count > maxPumpCurvePoints) {
      throw ArgumentError(
        'native_shaping block must have 0-$maxPumpCurvePoints points',
      );
    }
    final pointBytes = bytes.sublist(5);
    if (pointBytes.skip(count * 2).any((byte) => byte != 0)) {
      throw ArgumentError(
        'native_shaping block has unused bytes that are not 0',
      );
    }
    return _checked(
      version: supportedVersion,
      pressureBytes: [for (var i = 0; i < count; i++) pointBytes[i * 2]],
      flowBytes: [for (var i = 0; i < count; i++) pointBytes[i * 2 + 1]],
      flowTauByte: bytes[2],
      flowMode: flowMode,
      pressureTauByte: bytes[3],
      pressureMode: pressureMode,
      rampByte: bytes[4],
    );
  }

  static NativeShaping _checked({
    required int version,
    required List<int> pressureBytes,
    required List<int> flowBytes,
    required int flowTauByte,
    required NativeShapingMode flowMode,
    required int pressureTauByte,
    required NativeShapingMode pressureMode,
    required int rampByte,
  }) {
    _checkRange(flowTauByte, 0, _maxTauByte, 'flow_tau', '0-5 s');
    _checkRange(pressureTauByte, 0, _maxTauByte, 'pressure_tau', '0-5 s');
    _checkRange(rampByte, 0, _maxRampByte, 'ramp_factor', '0-4');
    for (var i = 0; i < pressureBytes.length; i++) {
      _checkRange(
        pressureBytes[i],
        _minPressureByte,
        _maxPressureByte,
        'pump_curve[$i].pressure',
        '0.5-13.5 bar',
      );
      if (i > 0 &&
          pressureBytes[i] < pressureBytes[i - 1] + _minPressureRiseBytes) {
        throw ArgumentError(
          'native_shaping "pump_curve[$i].pressure" must be at least 0.5 bar '
          'above the previous point after rounding to 0.1',
        );
      }
    }
    for (var i = 0; i < flowBytes.length; i++) {
      _checkRange(
        flowBytes[i],
        0,
        _maxFlowByte,
        'pump_curve[$i].flow',
        '0-20 mL/s',
      );
      if (i > 0 && flowBytes[i] > flowBytes[i - 1]) {
        throw ArgumentError(
          'native_shaping "pump_curve[$i].flow" must not rise above the '
          'previous point after rounding to 0.1',
        );
      }
    }
    return NativeShaping._(
      version: version,
      pumpCurve: List.unmodifiable([
        for (var i = 0; i < pressureBytes.length; i++)
          PumpCurvePoint._(
            pressureBytes[i] / _pointDivisor,
            flowBytes[i] / _pointDivisor,
          ),
      ]),
      flowTau: flowTauByte / _tauDivisor,
      flowMode: flowMode,
      pressureTau: pressureTauByte / _tauDivisor,
      pressureMode: pressureMode,
      rampFactor: rampByte / _rampDivisor,
    );
  }

  static int _parseVersion(Object? raw) {
    if (raw == null) return supportedVersion;
    if (raw is num && raw == supportedVersion) return supportedVersion;
    throw ArgumentError(
      'native_shaping "version" must be $supportedVersion, got $raw',
    );
  }

  static int _wireByte(
    Object? raw,
    String field,
    double divisor, {
    bool required = false,
    double absent = 0,
  }) {
    if (raw == null && !required) return (absent * divisor).round();
    final number = raw is num
        ? raw.toDouble()
        : raw is String
        ? double.tryParse(raw)
        : null;
    if (number == null) {
      throw ArgumentError('native_shaping "$field" must be a number');
    }
    if (!number.isFinite) {
      throw ArgumentError('native_shaping "$field" must be a finite number');
    }
    final scaled = (number * divisor).roundToDouble();
    if (scaled < 0 || scaled > 255) {
      throw ArgumentError(
        'native_shaping "$field" is out of range, got $number',
      );
    }
    return scaled.toInt();
  }

  static void _checkRange(
    int byte,
    int min,
    int max,
    String field,
    String range,
  ) {
    if (byte < min || byte > max) {
      throw ArgumentError(
        'native_shaping "$field" must be $range after rounding to its step',
      );
    }
  }

  List<int> toBlockBytes() {
    final bytes = List<int>.filled(blockLength, 0);
    bytes[0] = version;
    bytes[1] = flowMode.code << 6 | pressureMode.code << 4 | pumpCurve.length;
    bytes[2] = (flowTau * _tauDivisor).round();
    bytes[3] = (pressureTau * _tauDivisor).round();
    bytes[4] = (rampFactor * _rampDivisor).round();
    for (final (index, point) in pumpCurve.indexed) {
      bytes[5 + index * 2] = (point.pressure * _pointDivisor).round();
      bytes[6 + index * 2] = (point.flow * _pointDivisor).round();
    }
    return bytes;
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'pump_curve': pumpCurve.map((point) => point.toJson()).toList(),
    'flow_tau': flowTau,
    'flow_mode': flowMode.name,
    'pressure_tau': pressureTau,
    'pressure_mode': pressureMode.name,
    'ramp_factor': rampFactor,
  };

  @override
  List<Object?> get props => [
    version,
    pumpCurve,
    flowTau,
    flowMode,
    pressureTau,
    pressureMode,
    rampFactor,
  ];
}

enum NativeShapingSource {
  cli(0),
  profile(1),
  cliBlockRefused(2),
  inactive(3),
  unknown(-1);

  const NativeShapingSource(this.code);

  final int code;

  static NativeShapingSource fromCode(int code) =>
      values.firstWhere((s) => s.code == code, orElse: () => unknown);
}

enum NativeShapingRefusal {
  none(0),
  version(1),
  modeCode(2),
  pointCount(3),
  tauRange(4),
  rampRange(5),
  unusedBytes(6),
  pressureRange(7),
  pressureRise(8),
  flowRange(9),
  flowRise(10),
  unknown(-1);

  const NativeShapingRefusal(this.code);

  final int code;

  static NativeShapingRefusal fromCode(int code) =>
      values.firstWhere((r) => r.code == code, orElse: () => unknown);
}

@immutable
class NativeShapingReport extends Equatable {
  static const length = 32;
  static const _settingsOffset = 4;
  static const _roundedFlag = 0x01;

  final int sourceCode;
  final int refusalCode;
  final int latchCount;
  final bool settingsRounded;
  final NativeShaping? settings;

  const NativeShapingReport({
    required this.sourceCode,
    required this.refusalCode,
    required this.latchCount,
    required this.settingsRounded,
    required this.settings,
  });

  NativeShapingSource get source => NativeShapingSource.fromCode(sourceCode);

  NativeShapingRefusal get refusal =>
      NativeShapingRefusal.fromCode(refusalCode);

  factory NativeShapingReport.fromBytes(List<int> bytes) {
    if (bytes.length != length) {
      throw ArgumentError(
        'native shaping report must be $length bytes, got ${bytes.length}',
      );
    }
    return NativeShapingReport(
      sourceCode: bytes[0],
      refusalCode: bytes[1],
      latchCount: bytes[2],
      settingsRounded: bytes[3] & _roundedFlag != 0,
      settings: _settingsOrNull(
        bytes.sublist(
          _settingsOffset,
          _settingsOffset + NativeShaping.blockLength,
        ),
      ),
    );
  }

  static NativeShaping? _settingsOrNull(List<int> block) {
    try {
      return NativeShaping.fromBlockBytes(block);
    } on ArgumentError {
      return null;
    }
  }

  static NativeShapingReport? tryFromJson(Object? json) {
    if (json is! Map) return null;
    try {
      return NativeShapingReport.fromJson(Map<String, dynamic>.from(json));
    } on ArgumentError {
      return null;
    } on TypeError {
      return null;
    }
  }

  factory NativeShapingReport.fromJson(Map<String, dynamic> json) {
    final settings = json['settings'];
    return NativeShapingReport(
      sourceCode: json['sourceCode'] as int,
      refusalCode: json['refusalCode'] as int,
      latchCount: json['latchCount'] as int,
      settingsRounded: json['settingsRounded'] == true,
      settings: settings is Map
          ? NativeShaping.fromJson(Map<String, dynamic>.from(settings))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'source': source.name,
    'sourceCode': sourceCode,
    'refusal': refusal.name,
    'refusalCode': refusalCode,
    'latchCount': latchCount,
    'settingsRounded': settingsRounded,
    if (settings != null) 'settings': settings!.toJson(),
  };

  @override
  List<Object?> get props => [
    sourceCode,
    refusalCode,
    latchCount,
    settingsRounded,
    settings,
  ];
}
