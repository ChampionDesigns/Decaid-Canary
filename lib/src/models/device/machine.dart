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

  /// Integrated-scale weight in grams (Bengle `0xA013`, already net of tare).
  /// `0.0` on machines without an integrated scale.
  final double weight;

  /// Gravimetric flow in g/s from the integrated scale (Bengle `0xA013`
  /// GFlow). `0.0` on machines without an integrated scale.
  final double weightFlow;

  /// Milk-probe temperature in °C (Bengle `0xA013`). `0.0` when the firmware
  /// does not provide it (no probe / no fresh reading).
  final double milkTemperature;

  // Fused puck-estimator outputs streamed from the Bengle `0xA014` sample.
  // These are STORED, not recomputed on read: they are firmware-computed and
  // cannot be reconstructed from pressure/flow, so they must survive a history
  // round-trip. `null` = the estimator has not observed that quantity (no
  // estimator frame yet, or the field's wire sentinel). Each is omitted from
  // [toJson] when null and read-if-present in [fromJson].

  /// Fused puck resistance, n=1 convention (R1, bar·s/mL). `null` = unobserved.
  final double? fusedR1;

  /// Fused puck resistance, n=2 convention (R2, bar·s²/mL²). `null` =
  /// unobserved.
  final double? fusedR2;

  /// Fused compliance (C, mL/bar). `null` = unobserved.
  final double? fusedC;

  /// Fused resistance confidence 0..1. `null` = no estimator frame yet.
  final double? fusedConf;

  /// Absorbed / voids volume estimate V_abs (mL). `null` = n/a.
  final double? vAbs;

  /// Estimated Qout lag (seconds). `null` = no usable lag estimate.
  final double? estLag;

  /// Opaque estimator status-flags byte (see `bengle_est_sample.dart`). `null`
  /// = no estimator frame yet.
  final int? estFlags;

  // R1-collapse detector summary carried on the Bengle `0xA014` Rev-2 tail.
  // Pure observer output — the detector drives no machine behaviour. Like the
  // fused fields these are STORED so a history round-trip keeps them. `null` =
  // no Rev-2 detector tail on the estimator frame (or, for the three
  // descriptors, the field's own wire sentinel). [detEventCount] `0` is a REAL
  // value — no R1 collapse yet this shot — and is emitted, not omitted, so a
  // consumer can tell "detector ran, none seen" from "no detector".

  /// Confirmed R1-collapse events so far this shot. `null` = no detector tail.
  final int? detEventCount;

  /// Onset time t0 of the most recent R1-collapse event (seconds). `null` =
  /// none yet or no detector tail.
  final double? detLastEventT;

  /// Drop magnitude of the most recent R1-collapse event, `1 − R1/R1_ref` in
  /// 0..1. `null` = none or no detector tail.
  final double? detLastEventMag;

  /// Drop concentration of the most recent R1-collapse event, 0..1 (≈1 cliff,
  /// ≈0.33 ramp). `null` = none / undefined or no detector tail.
  final double? detLastEventConc;

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
    this.weight = 0.0,
    this.weightFlow = 0.0,
    this.milkTemperature = 0.0,
    this.fusedR1,
    this.fusedR2,
    this.fusedC,
    this.fusedConf,
    this.vAbs,
    this.estLag,
    this.estFlags,
    this.detEventCount,
    this.detLastEventT,
    this.detLastEventMag,
    this.detLastEventConc,
  });

  // CopyWith Method
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
    double? weight,
    double? weightFlow,
    double? milkTemperature,
    double? fusedR1,
    double? fusedR2,
    double? fusedC,
    double? fusedConf,
    double? vAbs,
    double? estLag,
    int? estFlags,
    int? detEventCount,
    double? detLastEventT,
    double? detLastEventMag,
    double? detLastEventConc,
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
      weight: weight ?? this.weight,
      weightFlow: weightFlow ?? this.weightFlow,
      milkTemperature: milkTemperature ?? this.milkTemperature,
      // Nullable additive estimator + detector fields follow the weight-style
      // `?? this` carry-forward; copyWith cannot null them back out (no caller
      // needs to), matching the other additive fields' convention.
      fusedR1: fusedR1 ?? this.fusedR1,
      fusedR2: fusedR2 ?? this.fusedR2,
      fusedC: fusedC ?? this.fusedC,
      fusedConf: fusedConf ?? this.fusedConf,
      vAbs: vAbs ?? this.vAbs,
      estLag: estLag ?? this.estLag,
      estFlags: estFlags ?? this.estFlags,
      detEventCount: detEventCount ?? this.detEventCount,
      detLastEventT: detLastEventT ?? this.detLastEventT,
      detLastEventMag: detLastEventMag ?? this.detLastEventMag,
      detLastEventConc: detLastEventConc ?? this.detLastEventConc,
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
      'weight': weight,
      'weightFlow': weightFlow,
      'milkTemperature': milkTemperature,
      // Fused-estimator keys: emitted only when observed. Absence (not null) is
      // the version-skew contract — old consumers never see them, and a
      // consumer can read key presence as the "observed" signal.
      if (fusedR1 != null) 'fusedR1': fusedR1,
      if (fusedR2 != null) 'fusedR2': fusedR2,
      if (fusedC != null) 'fusedC': fusedC,
      if (fusedConf != null) 'fusedConf': fusedConf,
      if (vAbs != null) 'vAbs': vAbs,
      if (estLag != null) 'estLag': estLag,
      if (estFlags != null) 'estFlags': estFlags,
      // R1-collapse detector keys: same omit-when-null rule, but detEventCount
      // 0 IS emitted (0 != null) so a consumer can tell "detector ran, no
      // collapse" from "no detector at all".
      if (detEventCount != null) 'detEventCount': detEventCount,
      if (detLastEventT != null) 'detLastEventT': detLastEventT,
      if (detLastEventMag != null) 'detLastEventMag': detLastEventMag,
      if (detLastEventConc != null) 'detLastEventConc': detLastEventConc,
    };
  }

  factory MachineSnapshot.fromJson(Map<String, dynamic> json) {
    return MachineSnapshot(
      timestamp: DateTime.parse(json["timestamp"]),
      state: MachineStateSnapshot(
        state: MachineState.values.firstWhere(
          (e) => e.name == json["state"]["state"],
        ),
        substate: MachineSubstate.values.firstWhere(
          (e) => e.name == json["state"]["substate"],
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
      // Additive fields — default 0.0 so older payloads still decode.
      weight: (json["weight"] ?? 0.0).toDouble(),
      weightFlow: (json["weightFlow"] ?? 0.0).toDouble(),
      milkTemperature: (json["milkTemperature"] ?? 0.0).toDouble(),
      // Nullable additive estimator + detector fields — read-if-present so both
      // pre-estimator history and gated frames (key absent) round-trip to null
      // rather than a fabricated 0.
      fusedR1: (json["fusedR1"] as num?)?.toDouble(),
      fusedR2: (json["fusedR2"] as num?)?.toDouble(),
      fusedC: (json["fusedC"] as num?)?.toDouble(),
      fusedConf: (json["fusedConf"] as num?)?.toDouble(),
      vAbs: (json["vAbs"] as num?)?.toDouble(),
      estLag: (json["estLag"] as num?)?.toDouble(),
      estFlags: (json["estFlags"] as num?)?.toInt(),
      detEventCount: (json["detEventCount"] as num?)?.toInt(),
      detLastEventT: (json["detLastEventT"] as num?)?.toDouble(),
      detLastEventMag: (json["detLastEventMag"] as num?)?.toDouble(),
      detLastEventConc: (json["detLastEventConc"] as num?)?.toDouble(),
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
  preparingForShot, // water heating, stabilizing water temp, ...
  preinfusion,
  pouring,
  pouringDone,
  cleaningStart, // same for descale
  cleaningGroup, // same for descale
  cleanSoaking,
  cleaningSteam,

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
}

class MachineStateSnapshot {
  const MachineStateSnapshot({required this.state, required this.substate});
  final MachineState state;
  final MachineSubstate substate;
}
