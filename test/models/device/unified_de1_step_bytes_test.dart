import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/errors.dart';
import '../../helpers/fake_ble_transport.dart';

const _setpointByte = 2;
const _temperatureByte = 3;
const _secondsByte = 4;
const _exitByte = 5;
const _volumeByte = 6;

int _baseByte(double value, double scale) => (0.5 + value * scale).toInt();

double _nextDown(double value) {
  final bits = ByteData(8)..setFloat64(0, value);
  bits.setInt64(0, bits.getInt64(0) - 1);
  return bits.getFloat64(0);
}

ProfileStep _pressureStep(
  int index, {
  double pressure = 6.0,
  double temperature = 92,
  double seconds = 10,
  double volume = 0,
  double exitValue = 4.0,
  StepLimiter? limiter,
  TransitionType transition = TransitionType.smooth,
}) => ProfileStepPressure(
  name: 'step $index',
  pressure: pressure,
  seconds: seconds,
  temperature: temperature,
  sensor: TemperatureSensor.coffee,
  transition: transition,
  volume: volume,
  exit: StepExitCondition(
    type: ExitType.flow,
    condition: ExitCondition.over,
    value: exitValue,
  ),
  limiter: limiter,
);

Profile _profile(List<ProfileStep> steps, {double tankTemperature = 93}) =>
    Profile(
      version: '2',
      title: 'step bytes',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      steps: steps,
      targetVolumeCountStart: 0,
      tankTemperature: tankTemperature,
    );

Map<int, Uint8List> _baseFrames(FakeBleTransport transport, int stepCount) => {
  for (final w in transport.writes)
    if (w.characteristicUUID == Endpoint.frameWrite.uuid &&
        w.data[0] < stepCount)
      w.data[0]: w.data,
};

class _Machine {
  const _Machine(this.name, this.build, this.scale, this.top, this.firstWrap);

  final String name;
  final UnifiedDe1 Function(FakeBleTransport) build;
  final double scale;
  final double top;
  final double firstWrap;
}

final _bengle = _Machine(
  'Bengle',
  (t) => Bengle(transport: t),
  10,
  25.5,
  25.55,
);
final _de1 = _Machine(
  'DE1',
  (t) => UnifiedDe1(transport: t),
  16,
  15.9375,
  15.96875,
);

List<(String, double, int)> _saturationRows(_Machine machine) => [
  ('-1', -1.0, 0),
  ('0', 0.0, 0),
  ('the top ${machine.top}', machine.top, 255),
  ('the first base wrap ${machine.firstWrap}', machine.firstWrap, 255),
  if (machine.name == 'Bengle') ('25.6', 25.6, 255),
  ('30', 30.0, 255),
  ('1e308', 1e308, 255),
  ('+Infinity', double.infinity, 255),
  ('-Infinity', double.negativeInfinity, 0),
];

List<double> _roundingValues(double scale) {
  final points = switch (scale) {
    10 => [9.05, 0.25, 25.45],
    16 => [9.53125, 0.03125, 15.90625],
    _ => [92.25, 0.25, 127.25],
  };
  return [
    for (final p in points) ...[p, _nextDown(p)],
  ];
}

Matcher _refusal(int? step, String field, double value) =>
    isA<ProfileValueUnsupportedException>()
        .having(
          (e) => e,
          'is a ProfileModeUnsupportedException',
          isA<ProfileModeUnsupportedException>(),
        )
        .having(
          (e) => e.message,
          'message',
          allOf([
            if (step != null) contains('step $step'),
            contains(field),
            contains('$value'),
          ]),
        );

Future<void> _expectRefused(
  UnifiedDe1 Function(FakeBleTransport) build,
  Profile profile,
  Matcher refusal, {
  Future<void> Function(FakeBleTransport, UnifiedDe1)? prepare,
}) async {
  final transport = FakeBleTransport();
  addTearDown(transport.dispose);
  final machine = build(transport);
  await prepare?.call(transport, machine);
  transport.writes.clear();
  await expectLater(machine.setProfile(profile), throwsA(refusal));
  expect(transport.writes, isEmpty, reason: 'no header, frame or MMR write');
}

Future<Map<int, Uint8List>> _upload(
  UnifiedDe1 Function(FakeBleTransport) build,
  List<ProfileStep> steps,
) async {
  final transport = FakeBleTransport();
  try {
    await build(transport).setProfile(_profile(steps));
    return _baseFrames(transport, steps.length);
  } finally {
    transport.dispose();
  }
}

Future<void> _capableBengle(FakeBleTransport transport, UnifiedDe1 de1) async {
  transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
  transport.queueOnConnectResponses(v13Model: 128, profileModeCaps: 0x7);
  await de1.onConnect();
}

void main() {
  test('the next lower doubles of the task text match', () {
    expect(_nextDown(9.05), 9.049999999999999);
    expect(_nextDown(92.25), 92.24999999999999);
  });

  group('saturatingByte keeps (0.5 + v * scale).toInt() in range', () {
    List<double> mismatches(int count, double divisor, double scale) => [
      for (var k = 0; k <= count; k++)
        if (Helper.saturatingByte(k / divisor, scale) !=
            _baseByte(k / divisor, scale))
          k / divisor,
    ];

    test('x10 on 0..25.5 in 0.001 steps', () {
      expect(mismatches(25500, 1000, 10), isEmpty);
    });

    test('x16 on 0..15.9375 in 1/1024 steps', () {
      expect(mismatches(16320, 1024, 16), isEmpty);
    });

    test('x16 on 0..15.937 in 0.001 steps', () {
      expect(mismatches(15937, 1000, 16), isEmpty);
    });

    test('NaN stays detectable (throws, never a byte)', () {
      expect(
        () => Helper.saturatingByte(double.nan, 10),
        throwsUnsupportedError,
      );
    });
  });

  for (final machine in [_bengle, _de1]) {
    group('${machine.name} step temperature', () {
      final inRange = <(String, double, int)>[
        ('0', 0.0, 0),
        ('127.5', 127.5, 255),
        for (final v in _roundingValues(2)) ('rounding $v', v, _baseByte(v, 2)),
      ];
      late Map<int, Uint8List> frames;

      setUpAll(() async {
        frames = await _upload(machine.build, [
          for (var i = 0; i < inRange.length; i++)
            _pressureStep(i, temperature: inRange[i].$2),
        ]);
      });

      for (var i = 0; i < inRange.length; i++) {
        final (label, _, expected) = inRange[i];
        test('$label -> $expected', () {
          expect(frames[i]?[_temperatureByte], expected);
        });
      }

      for (final v in [
        -0.1,
        -1.0,
        127.6,
        128.0,
        130.0,
        double.infinity,
        double.negativeInfinity,
      ]) {
        test('$v in a later step is refused before any write', () async {
          await _expectRefused(
            machine.build,
            _profile([_pressureStep(0), _pressureStep(1, temperature: v)]),
            _refusal(2, 'temperature', v),
          );
        });
      }

      test('-1 in the first step is refused before any write', () async {
        await _expectRefused(
          machine.build,
          _profile([_pressureStep(0, temperature: -1), _pressureStep(1)]),
          _refusal(1, 'temperature', -1),
        );
      });
    });

    group('${machine.name} exit value saturates', () {
      final rows = [
        ..._saturationRows(machine),
        for (final v in _roundingValues(machine.scale))
          ('rounding $v', v, _baseByte(v, machine.scale)),
      ];
      late Map<int, Uint8List> frames;

      setUpAll(() async {
        frames = await _upload(machine.build, [
          for (var i = 0; i < rows.length; i++)
            _pressureStep(i, exitValue: rows[i].$2),
        ]);
      });

      for (var i = 0; i < rows.length; i++) {
        final (label, _, expected) = rows[i];
        test('$label -> $expected', () {
          expect(frames[i]?[_exitByte], expected);
        });
      }
    });
  }

  group('DE1 flow/pressure setpoint saturates', () {
    final rows = [
      ..._saturationRows(_de1),
      for (final v in _roundingValues(16)) ('rounding $v', v, _baseByte(v, 16)),
    ];
    late Map<int, Uint8List> frames;

    setUpAll(() async {
      frames = await _upload(_de1.build, [
        for (var i = 0; i < rows.length; i++)
          _pressureStep(i, pressure: rows[i].$2),
      ]);
    });

    for (var i = 0; i < rows.length; i++) {
      final (label, _, expected) = rows[i];
      test('$label -> $expected', () {
        expect(frames[i]?[_setpointByte], expected);
      });
    }
  });

  for (final machine in [_bengle, _de1]) {
    group('${machine.name} refuses a value the encoder cannot encode, '
        'before any write', () {
      const nan = double.nan;
      final stepFields = <(String, ProfileStep Function(int))>[
        ('temperature', (i) => _pressureStep(i, temperature: nan)),
        ('exit value', (i) => _pressureStep(i, exitValue: nan)),
        ('pressure', (i) => _pressureStep(i, pressure: nan)),
        (
          'limiter value',
          (i) => _pressureStep(i, limiter: StepLimiter(value: nan, range: 1)),
        ),
        (
          'limiter range',
          (i) => _pressureStep(i, limiter: StepLimiter(value: 6, range: nan)),
        ),
      ];

      for (final (field, bad) in stepFields) {
        test('NaN $field in the first step', () async {
          await _expectRefused(
            machine.build,
            _profile([bad(0), _pressureStep(1)]),
            _refusal(1, field, nan),
          );
        });

        test('NaN $field in a later step', () async {
          await _expectRefused(
            machine.build,
            _profile([_pressureStep(0), _pressureStep(1), bad(2)]),
            _refusal(3, field, nan),
          );
        });
      }

      for (final (field, value, bad) in <(String, double, ProfileStep)>[
        ('seconds', nan, _pressureStep(1, seconds: nan)),
        (
          'seconds',
          double.negativeInfinity,
          _pressureStep(1, seconds: double.negativeInfinity),
        ),
        ('seconds', -1.0, _pressureStep(1, seconds: -1)),
        ('seconds', -12.0, _pressureStep(1, seconds: -12)),
        ('seconds', -1e308, _pressureStep(1, seconds: -1e308)),
        (
          'seconds',
          -double.maxFinite,
          _pressureStep(1, seconds: -double.maxFinite),
        ),
        ('volume', nan, _pressureStep(1, volume: nan)),
        ('volume', -5.0, _pressureStep(1, volume: -5)),
        ('volume', 1024.0, _pressureStep(1, volume: 1024)),
        ('volume', 2000.0, _pressureStep(1, volume: 2000)),
        ('volume', 65536.0, _pressureStep(1, volume: 65536)),
        (
          'volume',
          -double.maxFinite,
          _pressureStep(1, volume: -double.maxFinite),
        ),
        ('volume', double.infinity, _pressureStep(1, volume: double.infinity)),
        (
          'volume',
          double.negativeInfinity,
          _pressureStep(1, volume: double.negativeInfinity),
        ),
      ]) {
        test('$value $field in a later step', () async {
          await _expectRefused(
            machine.build,
            _profile([_pressureStep(0), bad]),
            _refusal(2, field, value),
          );
        });
      }

      test('NaN tank temperature', () async {
        await _expectRefused(
          machine.build,
          _profile([_pressureStep(0)], tankTemperature: nan),
          _refusal(null, 'tank temperature', nan),
        );
      });

      for (final (label, seconds) in <(String, double)>[
        ('1e308', 1e308),
        ('the largest double', double.maxFinite),
        ('+Infinity', double.infinity),
      ]) {
        test('$label seconds in a later step uploads as 255', () async {
          final frames = await _upload(machine.build, [
            _pressureStep(0),
            _pressureStep(1, seconds: seconds),
          ]);
          expect(frames[1]?[_secondsByte], 255);
        });
      }

      test('-0.0 seconds and -0.0 volume upload as 0', () async {
        final frames = await _upload(machine.build, [
          _pressureStep(0),
          _pressureStep(1, seconds: -0.0, volume: -0.0),
        ]);
        expect(frames[1]?[_secondsByte], 0);
        expect(frames[1]?.sublist(_volumeByte, _volumeByte + 2), [0x04, 0x00]);
      });

      test('the largest double volume is refused', () async {
        await _expectRefused(
          machine.build,
          _profile([
            _pressureStep(0),
            _pressureStep(1, volume: double.maxFinite),
          ]),
          _refusal(2, 'volume', double.maxFinite),
        );
      });

      test('1023 volume uploads as 07 FF', () async {
        final frames = await _upload(machine.build, [
          _pressureStep(0),
          _pressureStep(1, volume: 1023),
        ]);
        expect(frames[1]?.sublist(_volumeByte, _volumeByte + 2), [0x07, 0xFF]);
      });

      test(
        'a NaN limiter range under a 0 limiter value still uploads',
        () async {
          final frames = await _upload(machine.build, [
            _pressureStep(0),
            _pressureStep(1, limiter: StepLimiter(value: 0, range: nan)),
          ]);
          expect(frames.keys, [0, 1]);
        },
      );
    });
  }

  group('Bengle Lever, Power and HOLD fields', () {
    const nan = double.nan;
    ProfileStep lever({
      double spring = 0.9,
      double give = 1.5,
      StepLimiter? limiter,
    }) => ProfileStepLever(
      name: 'lever',
      transition: TransitionType.smooth,
      volume: 0,
      seconds: 30,
      temperature: 90,
      sensor: TemperatureSensor.coffee,
      pressure: 9.0,
      leverSpring: spring,
      leverGive: give,
      limiter: limiter,
    );
    ProfileStep power(StepLimiter limiter) => ProfileStepPower(
      name: 'power',
      transition: TransitionType.smooth,
      volume: 0,
      seconds: 30,
      temperature: 90,
      sensor: TemperatureSensor.coffee,
      power: 40,
      limiter: limiter,
    );

    UnifiedDe1 build(FakeBleTransport t) => UnifiedDe1(transport: t);

    for (final (field, bad) in <(String, ProfileStep)>[
      ('lever spring', lever(spring: nan)),
      ('lever give', lever(give: nan)),
      ('limiter value', lever(limiter: StepLimiter(value: nan, range: 1))),
      ('limiter range', lever(limiter: StepLimiter(value: 6, range: nan))),
      ('limiter value', power(StepLimiter(value: nan, range: 1))),
      (
        'limiter value',
        _pressureStep(
          1,
          transition: TransitionType.hold,
          limiter: StepLimiter(value: nan, range: 1),
        ),
      ),
      (
        'limiter range',
        _pressureStep(
          1,
          transition: TransitionType.hold,
          limiter: StepLimiter(value: 6, range: nan),
        ),
      ),
    ]) {
      test('NaN $field in a ${bad.runtimeType} step', () async {
        await _expectRefused(
          build,
          _profile([_pressureStep(0), bad]),
          _refusal(2, field, nan),
          prepare: _capableBengle,
        );
      });
    }

    for (final (label, step) in <(String, ProfileStep)>[
      ('a NaN Power limiter range', power(StepLimiter(value: 8, range: nan))),
      (
        'a NaN HOLD step pressure',
        _pressureStep(1, transition: TransitionType.hold, pressure: nan),
      ),
    ]) {
      test('$label is not encoded and still uploads', () async {
        final transport = FakeBleTransport();
        addTearDown(transport.dispose);
        final de1 = build(transport);
        await _capableBengle(transport, de1);
        transport.writes.clear();
        await de1.setProfile(_profile([_pressureStep(0), step]));
        expect(_baseFrames(transport, 2).keys, [0, 1]);
      });
    }
  });
}
