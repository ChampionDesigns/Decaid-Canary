import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import '../../helpers/fake_ble_transport.dart';

ProfileStepFlow _limitedStep(int index, double value, double range) =>
    ProfileStepFlow(
      name: 'limited $index',
      flow: 2.0,
      seconds: 10,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.smooth,
      volume: 0,
      limiter: StepLimiter(value: value, range: range),
    );

Profile _limiterProfile(List<(double, double)> limiters) => Profile(
  version: '2',
  title: 'limiter bytes',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  steps: [
    for (var i = 0; i < limiters.length; i++)
      _limitedStep(i, limiters[i].$1, limiters[i].$2),
  ],
  targetVolumeCountStart: 0,
  tankTemperature: 93,
);

List<Uint8List> _extensionFrames(FakeBleTransport transport) => transport.writes
    .where(
      (w) =>
          w.characteristicUUID == Endpoint.frameWrite.uuid && w.data[0] >= 32,
    )
    .map((w) => w.data)
    .toList();

class _Machine {
  const _Machine(this.name, this.build, this.top, this.aboveTop, this.inRange);

  final String name;
  final UnifiedDe1 Function(FakeBleTransport) build;
  final double top;
  final double aboveTop;
  final (double, int) inRange;
}

final _machines = [
  _Machine('Bengle', (t) => Bengle(transport: t), 25.5, 25.6, (4.4, 44)),
  _Machine('DE1', (t) => UnifiedDe1(transport: t), 15.9375, 15.95, (9.5, 152)),
];

void main() {
  group('limiter byte helpers keep every in-range byte', () {
    List<double> mismatches(
      int count,
      double divisor,
      int Function(double) helper,
      double scale,
    ) => [
      for (var k = 0; k <= count; k++)
        if (helper(k / divisor) != (0.5 + (k / divisor) * scale).toInt())
          k / divisor,
    ];

    test('U8D1 keeps (0.5 + v * 10).toInt() on 0..25.5 in 0.001 steps', () {
      expect(
        mismatches(25500, 1000, Helper.convert_float_to_U8D1, 10),
        isEmpty,
      );
    });

    test('U8P4 keeps (0.5 + v * 16).toInt() on 0..15.9375 in 1/1024 steps', () {
      expect(
        mismatches(16320, 1024, Helper.convert_float_to_U8P4, 16),
        isEmpty,
      );
    });

    test('U8P4 keeps (0.5 + v * 16).toInt() on 0..15.937 in 0.001 steps', () {
      expect(
        mismatches(15937, 1000, Helper.convert_float_to_U8P4, 16),
        isEmpty,
      );
    });
  });

  for (final machine in _machines) {
    group('${machine.name} limiter bytes saturate', () {
      final (inValue, inByte) = machine.inRange;
      final rows = <(String, double, int)>[
        ('-1', -1.0, 0),
        ('the top value', machine.top, 255),
        ('one step above the top', machine.aboveTop, 255),
        ('30', 30.0, 255),
        ('1e308', 1e308, 255),
        ('+Infinity', double.infinity, 255),
        ('-Infinity', double.negativeInfinity, 0),
        ('in range $inValue', inValue, inByte),
      ];

      Future<Map<int, Uint8List>> upload(
        List<(double, double)> limiters,
      ) async {
        final transport = FakeBleTransport();
        try {
          await machine.build(transport).setProfile(_limiterProfile(limiters));
          return {for (final f in _extensionFrames(transport)) f[0] - 32: f};
        } finally {
          transport.dispose();
        }
      }

      group('limiter value', () {
        late Map<int, Uint8List> frames;

        setUpAll(() async {
          frames = await upload([
            for (final row in rows) (row.$2, 1.0),
            (0.0, 1.0),
          ]);
        });

        for (var i = 0; i < rows.length; i++) {
          final (label, _, expected) = rows[i];
          test('$label -> $expected', () {
            expect(frames[i]?[1], expected);
          });
        }

        test('0 sends no extension frame', () {
          expect(frames.keys, isNot(contains(rows.length)));
          expect(frames, hasLength(rows.length));
        });
      });

      group('limiter range', () {
        late Map<int, Uint8List> frames;

        setUpAll(() async {
          frames = await upload([
            for (final row in rows) (inValue, row.$2),
            (inValue, 0.0),
          ]);
        });

        for (var i = 0; i < rows.length; i++) {
          final (label, _, expected) = rows[i];
          test('$label -> $expected', () {
            expect(frames[i]?[2], expected);
            expect(frames[i]?[1], inByte);
          });
        }

        test('0 -> 0', () {
          expect(frames[rows.length]?[2], 0);
        });
      });

      for (final (field, limiter) in [
        ('value', (double.nan, 1.0)),
        ('range', (inValue, double.nan)),
      ]) {
        test('limiter $field NaN fails the upload before any frame', () async {
          final transport = FakeBleTransport();
          addTearDown(transport.dispose);
          await expectLater(
            machine.build(transport).setProfile(_limiterProfile([limiter])),
            throwsUnsupportedError,
          );
          expect(_extensionFrames(transport), isEmpty);
        });
      }
    });
  }
}
