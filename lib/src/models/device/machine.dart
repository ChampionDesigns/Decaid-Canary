import 'package:reaprime/src/models/device/device.dart';

abstract class Machine extends Device {
  Stream<MachineSnapshot> get currentSnapshot;

  MachineInfo get machineInfo;

  Future<void> requestState(MachineState newState);
}

class MachineInfo {
  final String version;
  final String model;
  final String serialNumber;
  final bool groupHeadControllerPresent;
  final Map<String, dynamic> extra;

  MachineInfo({
    required this.version,
    required this.model,
    required this.serialNumber,
    required this.groupHeadControllerPresent,
    required this.extra,
  });

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'model': model,
      'serialNumber': serialNumber,
      'GHC': groupHeadControllerPresent,
      'extra': extra,
    };
  }
}

class MachineSnapshot {
  final DateTime timestamp;
  final MachineStateSnapshot state;
  final double flow;
  final double pressure;
  final double targetFlow;
  final double targetPressure;
  final double mixTemperature;
  final double groupTemperature;
  final double targetMixTemperature;
  final double targetGroupTemperature;
  final int profileFrame;
  final int steamTemperature;

  MachineSnapshot({
    required this.timestamp,
    required this.state,
    required this.flow,
    required this.pressure,
    required this.targetFlow,
    required this.targetPressure,
    required this.mixTemperature,
    required this.groupTemperature,
    required this.targetMixTemperature,
    required this.targetGroupTemperature,
    required this.profileFrame,
    required this.steamTemperature,
  });

  /// Shared gate for the derived channels: returns [value] only when
  /// `flow >= 0.3 mL/s && pressure >= 0.3 bar` (below that the ratios are
  /// numerically meaningless noise) and inputs and result are finite. The
  /// finite guard is mandatory: `jsonEncode` throws on NaN/Infinity and
  /// [toJson] is streamed on the live `/ws/v1/machine/snapshot` websocket.
  double? _derivedOrNull(double value) {
    if (flow < 0.3 || pressure < 0.3) return null;
    if (!flow.isFinite || !pressure.isFinite || !value.isFinite) return null;
    return value;
  }

  /// Puck hydraulic resistance **R = P / F²** in bar·s²/mL², DERIVED.
  ///
  /// How strongly the puck resists water flow; rises as the puck compacts
  /// or clogs, drops on channeling/erosion. `null` (and omitted from
  /// [toJson]) unless flow ≥ 0.3 mL/s and pressure ≥ 0.3 bar.
  ///
  /// Measured equivalent: `r2` on the puck-estimator sensor (the firmware's
  /// n=2 resistance fit). Prefer it when present.
  double? get puckResistanceDerived => _derivedOrNull(pressure / (flow * flow));

  /// Hydraulic load impedance **Z = P / F** in bar·s/mL, DERIVED.
  ///
  /// Pressure-to-flow ratio at the current operating point (the "AC"
  /// analogue of [puckResistanceDerived]). Same ≥ 0.3 gating.
  ///
  /// Measured equivalent: `r1` on the puck-estimator sensor (the firmware's
  /// n=1 resistance fit). Prefer it when present.
  double? get loadImpedanceDerived => _derivedOrNull(pressure / flow);

  /// Hydraulic power delivered to the puck **W = 0.1 · P · F** in watts,
  /// DERIVED (1 bar × 1 mL/s = 0.1 W; espresso is roughly 0.5–4 W).
  ///
  /// Same ≥ 0.3 gating as [puckResistanceDerived].
  ///
  /// Measured equivalent: `hydraulicPowerMeasured` on the puck-estimator
  /// sensor, present when the machine reports BengleEstSample rev ≥ 3. Prefer
  /// it when present — it uses Q_puck, so it is the power actually delivered
  /// rather than the power supplied.
  double? get hydraulicPowerDerived => _derivedOrNull(0.1 * pressure * flow);

  MachineSnapshot copyWith({
    DateTime? timestamp,
    MachineStateSnapshot? state,
    double? flow,
    double? pressure,
    double? targetFlow,
    double? targetPressure,
    double? mixTemperature,
    double? groupTemperature,
    double? targetMixTemperature,
    double? targetGroupTemperature,
    int? profileFrame,
    int? steamTemperature,
  }) {
    return MachineSnapshot(
      timestamp: timestamp ?? this.timestamp,
      state: state ?? this.state,
      flow: flow ?? this.flow,
      pressure: pressure ?? this.pressure,
      targetFlow: targetFlow ?? this.targetFlow,
      targetPressure: targetPressure ?? this.targetPressure,
      mixTemperature: mixTemperature ?? this.mixTemperature,
      groupTemperature: groupTemperature ?? this.groupTemperature,
      targetMixTemperature: targetMixTemperature ?? this.targetMixTemperature,
      targetGroupTemperature:
          targetGroupTemperature ?? this.targetGroupTemperature,
      profileFrame: profileFrame ?? this.profileFrame,
      steamTemperature: steamTemperature ?? this.steamTemperature,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'state': {'state': state.state.name, 'substate': state.substate.name},
      'flow': flow,
      'pressure': pressure,
      'targetFlow': targetFlow,
      'targetPressure': targetPressure,
      'mixTemperature': mixTemperature,
      'groupTemperature': groupTemperature,
      'targetMixTemperature': targetMixTemperature,
      'targetGroupTemperature': targetGroupTemperature,
      'profileFrame': profileFrame,
      'steamTemperature': steamTemperature,
      if (puckResistanceDerived != null)
        'puckResistanceDerived': puckResistanceDerived,
      if (loadImpedanceDerived != null)
        'loadImpedanceDerived': loadImpedanceDerived,
      if (hydraulicPowerDerived != null)
        'hydraulicPowerDerived': hydraulicPowerDerived,
    };
  }

  factory MachineSnapshot.fromJson(Map<String, dynamic> json) {
    return MachineSnapshot(
      timestamp: DateTime.parse(json["timestamp"]),
      state: MachineStateSnapshot(
        state: MachineState.values.firstWhere(
          (e) => e.name == json["state"]["state"],
          orElse: () => MachineState.error,
        ),
        substate: MachineSubstate.values.firstWhere(
          (e) => e.name == json["state"]["substate"],
          orElse: () => MachineSubstate.idle,
        ),
      ),
      flow: json["flow"],
      pressure: json["pressure"],
      targetFlow: json["targetFlow"],
      targetPressure: json["targetPressure"],
      mixTemperature: json["mixTemperature"],
      groupTemperature: json["groupTemperature"],
      targetMixTemperature: json["targetMixTemperature"],
      targetGroupTemperature: json["targetGroupTemperature"],
      profileFrame: json["profileFrame"],
      steamTemperature: json["steamTemperature"],
    );
  }
}

enum MachineState {
  booting,
  busy,
  idle,
  schedIdle,
  sleeping,
  heating,
  preheating,
  espresso,
  hotWater,
  flush,
  steam,
  steamRinse,
  skipStep,
  cleaning,
  descaling,
  calibration,
  selfTest,
  airPurge,
  needsWater,
  error,
  fwUpgrade,
}

enum MachineSubstate {
  idle,
  preparingForShot,
  preinfusion,
  pouring,
  pouringDone,
  cleaningStart,
  cleaningGroup,
  cleanSoaking,
  cleaningSteam,

  /// Steam is paused between pours; the session is not over.
  pausedSteam,

  /// The purge after steam stops on time or on milk temperature.
  puffing,
  refillStopped,
  pumpZeroing,

  errorNaN,
  errorInf,
  errorGeneric,
  errorAcc,
  errorTSensor,
  errorPSensor,
  errorWLevel,
  errorDip,
  errorAssertion,
  errorUnsafe,
  errorInvalidParam,
  errorFlash,
  errorOOM,
  errorDeadline,
  errorHiCurrent,
  errorLoCurrent,
  errorBootFill,
  errorNoAC,
  errorPumpZero,
  errorPumpNeedsCalibration,
  errorFrontSwitchOff,
  errorPumpFault,
  errorPumpSilent,
}

class MachineStateSnapshot {
  const MachineStateSnapshot({required this.state, required this.substate});
  final MachineState state;
  final MachineSubstate substate;
}
