import 'package:reaprime/src/models/data/profile.dart';

class NonDe1ProfileStep extends ProfileStep {
  const NonDe1ProfileStep()
    : super(
        name: 'non-de1',
        transition: TransitionType.fast,
        volume: 0,
        seconds: 10,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
      );

  @override
  double getTarget() => 5;

  @override
  Map<String, dynamic> toJson() => {'name': name, 'pump': 'non-de1'};

  @override
  ProfileStep copyWith({double? temperature}) => this;

  @override
  List<Object?> get props => [name];
}
