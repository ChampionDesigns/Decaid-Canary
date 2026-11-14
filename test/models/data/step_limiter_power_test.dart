import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  Map<String, dynamic> powerStepJson({
    dynamic limiter,
    String transition = 'fast',
  }) => {
    'name': 'power pour',
    'pump': 'power',
    'transition': transition,
    'volume': 0,
    'seconds': 25,
    'temperature': 93,
    'sensor': 'coffee',
    'power': 2.0,
    'limiter': limiter,
  };

  Matcher refusesNaming(String field) => throwsA(
    isA<FormatException>().having(
      (e) => e.message,
      'message',
      'limiter "$field" must be a number',
    ),
  );

  group('a power step parses its limiter with StepLimiter.fromJson', () {
    test('form (a) {value: 6} refuses by naming "range"', () {
      expect(
        () => ProfileStep.fromJson(powerStepJson(limiter: {'value': 6})),
        refusesNaming('range'),
      );
    });

    test('form (b) {value: 6, range: 0} parses with range 0', () {
      final step = ProfileStep.fromJson(
        powerStepJson(limiter: {'value': 6, 'range': 0}),
      );

      expect(step, isA<ProfileStepPower>());
      expect(step.limiter, equals(const StepLimiter(value: 6, range: 0)));
    });

    test('form (c) {value: 6, range: null} refuses by naming "range"', () {
      expect(
        () => ProfileStep.fromJson(
          powerStepJson(limiter: {'value': 6, 'range': null}),
        ),
        refusesNaming('range'),
      );
    });

    test('form (d) {range: 1} refuses by naming "value"', () {
      expect(
        () => ProfileStep.fromJson(powerStepJson(limiter: {'range': 1})),
        refusesNaming('value'),
      );
    });

    test('form (e) {value: null, range: 1} refuses by naming "value"', () {
      expect(
        () => ProfileStep.fromJson(
          powerStepJson(limiter: {'value': null, 'range': 1}),
        ),
        refusesNaming('value'),
      );
    });

    test('form (f) {value: 6, range: "x"} refuses by naming "range"', () {
      expect(
        () => ProfileStep.fromJson(
          powerStepJson(limiter: {'value': 6, 'range': 'x'}),
        ),
        refusesNaming('range'),
      );
    });

    test('a zero-value limiter is still refused by the power step', () {
      expect(
        () => ProfileStep.fromJson(
          powerStepJson(limiter: {'value': 0, 'range': 0}),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'power step requires a pressure limiter',
          ),
        ),
      );
    });

    for (final (limiter, field) in [
      (<String, dynamic>{'value': 'NaN', 'range': 1}, 'value'),
      (<String, dynamic>{'value': 'Infinity', 'range': 1}, 'value'),
      (<String, dynamic>{'value': 6, 'range': 'NaN'}, 'range'),
      (<String, dynamic>{'value': 6, 'range': '-Infinity'}, 'range'),
      (<String, dynamic>{'value': double.infinity, 'range': 1}, 'value'),
    ]) {
      test('a non-finite limiter $limiter refuses by naming "$field"', () {
        expect(
          () => ProfileStep.fromJson(powerStepJson(limiter: limiter)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'limiter "$field" must be a finite number',
            ),
          ),
        );
      });
    }
  });

  group('encoder bytes for an accepted limiter', () {
    Profile profileOf(List<ProfileStep> steps) => Profile(
      version: '2',
      title: 'limiter encoding',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      steps: steps,
      targetVolumeCountStart: 0,
      tankTemperature: 0,
    );

    ProfileStep flowStep(StepLimiter limiter, {TransitionType? transition}) =>
        ProfileStepFlow(
          name: 'flow',
          transition: transition ?? TransitionType.fast,
          volume: 0,
          seconds: 20,
          temperature: 92,
          sensor: TemperatureSensor.coffee,
          flow: 2.0,
          limiter: limiter,
        );

    ProfileStep pressureStep(
      StepLimiter limiter, {
      TransitionType? transition,
    }) => ProfileStepPressure(
      name: 'pressure',
      transition: transition ?? TransitionType.fast,
      volume: 0,
      seconds: 20,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      pressure: 9.0,
      limiter: limiter,
    );

    ProfileStep powerStep(StepLimiter limiter, {TransitionType? transition}) =>
        ProfileStepPower(
          name: 'power',
          transition: transition ?? TransitionType.fast,
          volume: 0,
          seconds: 20,
          temperature: 92,
          sensor: TemperatureSensor.coffee,
          power: 2.0,
          limiter: limiter,
        );

    Future<Map<int, List<int>>> extFrames(
      Profile profile, {
      required bool bengle,
    }) async {
      final transport = FakeBleTransport();
      final de1 = UnifiedDe1(transport: transport);
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
      transport.queueOnConnectResponses(
        v13Model: bengle ? 128 : 1,
        profileModeCaps: bengle ? 0x7 : 0,
      );
      await de1.onConnect();
      await de1.setProfile(profile);
      final frames = {
        for (final w in transport.writes.where(
          (w) =>
              w.characteristicUUID == Endpoint.frameWrite.uuid &&
              w.data[0] >= 32,
        ))
          w.data[0]: w.data.toList(),
      };
      await transport.dispose();
      return frames;
    }

    const formB = StepLimiter(value: 6, range: 0);

    test('DE1: form (b) writes range byte 0 for flow and pressure', () async {
      final frames = await extFrames(
        profileOf([flowStep(formB), pressureStep(formB)]),
        bengle: false,
      );

      expect(frames[32], [32, 96, 0, 0, 0, 0, 0, 0]);
      expect(frames[33], [33, 96, 0, 0, 0, 0, 0, 0]);
    });

    test(
      'Bengle: form (b) writes range byte 0 for flow and pressure',
      () async {
        final frames = await extFrames(
          profileOf([flowStep(formB), pressureStep(formB)]),
          bengle: true,
        );

        expect(frames[32], [32, 60, 0, 0, 0, 0, 0, 0]);
        expect(frames[33], [33, 60, 0, 0, 0, 0, 0, 0]);
      },
    );

    test(
      'Bengle: form (b) writes range byte 0 for HOLD flow and pressure',
      () async {
        final frames = await extFrames(
          profileOf([
            flowStep(formB),
            flowStep(formB, transition: TransitionType.hold),
            pressureStep(formB, transition: TransitionType.hold),
          ]),
          bengle: true,
        );

        expect(frames[33], [33, 60, 0, 4, 0, 0, 0, 0]);
        expect(frames[34], [34, 60, 0, 3, 0, 0, 0, 0]);
      },
    );

    test('Bengle: power and HOLD-power frames encode only the value', () async {
      for (final limiter in const [
        StepLimiter(value: 9, range: 0),
        StepLimiter(value: 9, range: 0.6),
      ]) {
        final frames = await extFrames(
          profileOf([
            powerStep(limiter),
            powerStep(limiter, transition: TransitionType.hold),
          ]),
          bengle: true,
        );

        expect(frames[32], [32, 0, 0, 1, 0x5A, 0, 0, 0], reason: '$limiter');
        expect(frames[33], [33, 0, 0, 5, 0x5A, 0, 0, 0], reason: '$limiter');
      }
    });

    for (final transition in [TransitionType.fast, TransitionType.hold]) {
      for (final value in [0.0, -1.0, 0.01, 0.04, double.infinity]) {
        test('Bengle: a ${transition.name} power step with limiter value '
            '$value is refused before any write', () async {
          final transport = FakeBleTransport();
          addTearDown(transport.dispose);
          final de1 = UnifiedDe1(transport: transport);
          transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
          transport.queueOnConnectResponses(
            v13Model: 128,
            profileModeCaps: 0x7,
          );
          await de1.onConnect();
          transport.writes.clear();

          await expectLater(
            de1.setProfile(
              profileOf([
                pressureStep(formB),
                powerStep(
                  StepLimiter(value: value, range: 0),
                  transition: transition,
                ),
              ]),
            ),
            throwsA(
              isA<ProfileValueUnsupportedException>()
                  .having((e) => e.field, 'field', 'limiter value')
                  .having((e) => e.stepNumber, 'stepNumber', 2),
            ),
          );
          expect(transport.writes, isEmpty);
        });
      }

      test('Bengle: a ${transition.name} power step with limiter value 0.05 '
          'encodes ModeMaxP 1', () async {
        final frames = await extFrames(
          profileOf([
            pressureStep(formB),
            powerStep(
              const StepLimiter(value: 0.05, range: 0),
              transition: transition,
            ),
          ]),
          bengle: true,
        );

        expect(frames[33]![4], 1);
        expect(frames[33]![3], transition == TransitionType.hold ? 5 : 1);
      });
    }
  });
}
