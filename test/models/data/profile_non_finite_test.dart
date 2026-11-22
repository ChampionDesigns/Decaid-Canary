import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';

const _placeholder = 'NON_FINITE_PLACEHOLDER';

const _nonFiniteForms = <(String, String)>[
  ('the string "NaN"', '"NaN"'),
  ('the string "Infinity"', '"Infinity"'),
  ('the string "-Infinity"', '"-Infinity"'),
  ('the JSON number 1e400', '1e400'),
  ('the JSON number -1e400', '-1e400'),
];

Map<String, dynamic> _step(String pump) => {
  'name': 'pour',
  'pump': pump,
  'transition': 'fast',
  'volume': 0,
  'seconds': 30,
  'weight': 0,
  'temperature': 92,
  'sensor': 'coffee',
  'exit': {'type': 'pressure', 'condition': 'over', 'value': 4},
  if (pump == 'pressure') 'pressure': 9.0,
  if (pump == 'flow') 'flow': 2.0,
  if (pump == 'power') 'power': 3.0,
  if (pump == 'power') 'limiter': {'value': 9, 'range': 0.6},
  if (pump == 'lever') ...{
    'pressure': 9.0,
    'leverSpring': 0.5,
    'leverGive': 0.2,
  },
};

Map<String, dynamic> _profile(Map<String, dynamic> step) => {
  'version': '2',
  'title': 'non-finite',
  'beverage_type': 'espresso',
  'steps': <dynamic>[step],
  'tank_temperature': 0,
  'target_volume_count_start': 0,
};

Profile _parseWith(
  Map<String, dynamic> step,
  void Function(Map<String, dynamic> step) mark,
  String literal,
) {
  mark(step);
  final text = jsonEncode(_profile(step))
      .replaceFirst('"$_placeholder"', literal);
  return Profile.fromJson(jsonDecode(text) as Map<String, dynamic>);
}

Matcher _refusesStepField(String field) => throwsA(
  isA<FormatException>().having(
    (e) => e.message,
    'message',
    'step "$field" must be a finite number',
  ),
);

void main() {
  group('a non-finite step value is refused at parse', () {
    final cases = <(String, String)>[
      ('pressure', 'pressure'),
      ('flow', 'flow'),
      ('power', 'power'),
      ('lever', 'pressure'),
      ('lever', 'leverSpring'),
      ('lever', 'leverGive'),
      for (final pump in ['pressure', 'flow', 'power', 'lever']) ...[
        (pump, 'seconds'),
        (pump, 'volume'),
        (pump, 'temperature'),
        (pump, 'weight'),
      ],
    ];
    for (final (pump, field) in cases) {
      for (final (label, literal) in _nonFiniteForms) {
        test('a $pump step with $field $label', () {
          expect(
            () => _parseWith(
              _step(pump),
              (s) => s[field] = _placeholder,
              literal,
            ),
            _refusesStepField(field),
          );
        });
      }
    }
  });

  group('a non-finite exit value is refused at parse', () {
    for (final pump in ['pressure', 'flow', 'power', 'lever']) {
      for (final (label, literal) in _nonFiniteForms) {
        test('a $pump step with exit value $label', () {
          expect(
            () => _parseWith(
              _step(pump),
              (s) =>
                  (s['exit'] as Map<String, dynamic>)['value'] = _placeholder,
              literal,
            ),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                'exit "value" must be a finite number',
              ),
            ),
          );
        });
      }
    }
  });

  group('a non-finite limiter is refused at parse', () {
    for (final field in ['value', 'range']) {
      for (final (label, literal) in _nonFiniteForms) {
        test('limiter $field $label', () {
          expect(
            () => _parseWith(
              _step('pressure'),
              (s) =>
                  s['limiter'] = <String, dynamic>{'value': 6, 'range': 1}
                    ..[field] = _placeholder,
              literal,
            ),
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
    }
  });

  group('a non-finite profile value is refused at parse', () {
    for (final field in [
      'tank_temperature',
      'target_weight',
      'target_volume',
      'target_volume_count_start',
    ]) {
      for (final (label, literal) in _nonFiniteForms) {
        test('profile $field $label', () {
          final json = _profile(_step('pressure'))..[field] = _placeholder;
          final text = jsonEncode(json)
              .replaceFirst('"$_placeholder"', literal);
          expect(
            () => Profile.fromJson(jsonDecode(text) as Map<String, dynamic>),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                'profile "$field" must be a finite number',
              ),
            ),
          );
        });
      }
    }

    test('finite profile values still parse from numbers and strings', () {
      final profile = Profile.fromJson(
        _profile(_step('pressure'))
          ..['tank_temperature'] = '88.5'
          ..['target_weight'] = 36
          ..['target_volume'] = '40'
          ..['target_volume_count_start'] = 2.0,
      );
      expect(profile.tankTemperature, 88.5);
      expect(profile.targetWeight, 36);
      expect(profile.targetVolume, 40);
      expect(profile.targetVolumeCountStart, 2);
    });

    test('absent optional profile values stay absent', () {
      final json = _profile(_step('pressure'))
        ..remove('target_volume_count_start');
      final profile = Profile.fromRecordedJson(json);
      expect(profile.targetWeight, isNull);
      expect(profile.targetVolume, isNull);
      expect(profile.targetVolumeCountStart, 0);
    });
  });

  group('finite values still parse', () {
    for (final pump in ['pressure', 'flow', 'power', 'lever']) {
      test('a $pump step with string and number values', () {
        final step = _step(pump)
          ..['seconds'] = '25.5'
          ..['temperature'] = 93;
        final profile = Profile.fromJson(_profile(step));
        expect(profile.steps.single.seconds, 25.5);
        expect(profile.steps.single.temperature, 93);
        expect(profile.steps.single.exit!.value, 4);
      });
    }

    test('a step with no weight keeps a null weight', () {
      final step = _step('pressure')..remove('weight');
      expect(Profile.fromJson(_profile(step)).steps.single.weight, isNull);
    });
  });

  group('a lever step accepts both field spellings', () {
    Map<String, dynamic> snakeLever() {
      final step = _step('lever')
        ..remove('leverSpring')
        ..remove('leverGive');
      return step
        ..['lever_spring'] = 0.5
        ..['lever_give'] = 0.2;
    }

    test('lever_spring and lever_give import with the camelCase values', () {
      final snake = Profile.fromJson(_profile(snakeLever()));
      final camel = Profile.fromJson(_profile(_step('lever')));

      final step = snake.steps.single as ProfileStepLever;
      expect(step.leverSpring, 0.5);
      expect(step.leverGive, 0.2);
      expect(snake, equals(camel));
    });

    test('toJson writes the camelCase spelling', () {
      final json = Profile.fromJson(_profile(snakeLever())).steps.single
          .toJson();
      expect(json['leverSpring'], 0.5);
      expect(json['leverGive'], 0.2);
      expect(json.containsKey('lever_spring'), isFalse);
      expect(json.containsKey('lever_give'), isFalse);
    });

    test('a non-finite lever_spring is refused', () {
      expect(
        () => _parseWith(
          snakeLever(),
          (s) => s['lever_spring'] = _placeholder,
          '"Infinity"',
        ),
        _refusesStepField('leverSpring'),
      );
    });
  });
}
