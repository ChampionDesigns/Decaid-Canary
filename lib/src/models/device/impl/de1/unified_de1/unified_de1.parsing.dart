part of 'unified_de1.dart';

extension MessageParsing on UnifiedDe1 {
  MachineSnapshot _parseStateAndShotSample(
    ByteData stateSample,
    ByteData shotSample,
  ) {
    final groupPressure = shotSample.getUint16(2) / (1 << 12);
    final groupFlow = shotSample.getUint16(4) / (1 << 12);
    final mixTemp = shotSample.getUint16(6) / (1 << 8);
    final headTemp =
        ((shotSample.getUint8(8) << 16) +
            (shotSample.getUint8(9) << 8) +
            (shotSample.getUint8(10))) /
        (1 << 16);
    final setMixTemp = shotSample.getUint16(11) / (1 << 8);
    final setHeadTemp = shotSample.getUint16(13) / (1 << 8);
    final setGroupPressure = shotSample.getUint8(15) / (1 << 4);
    final setGroupFlow = shotSample.getUint8(16) / (1 << 4);
    final frameNumber = shotSample.getUint8(17);
    final steamTemp = shotSample.getUint8(18);

    var state = De1StateEnum.fromHexValue(stateSample.getUint8(0));
    var subState =
        De1SubState.fromHexValue(stateSample.getUint8(1)) ??
        De1SubState.noState;

    return MachineSnapshot(
      timestamp: DateTime.now(),
      state: MachineStateSnapshot(
        state: mapDe1ToMachineState(state),
        substate: mapDe1SubToMachineSubstate(subState),
      ),
      pressure: groupPressure,
      flow: groupFlow,
      mixTemperature: mixTemp,
      groupTemperature: headTemp,
      targetMixTemperature: setMixTemp,
      targetGroupTemperature: setHeadTemp,
      targetPressure: setGroupPressure,
      targetFlow: setGroupFlow,
      profileFrame: frameNumber,
      steamTemperature: steamTemp,
    );
  }

  /// Build a [MachineSnapshot] from a Bengle `0xA013` BengleShotSample frame
  /// (the sole snapshot source on a Bengle) plus the latest DE1 state
  /// frame (state layout is unchanged, so it is read exactly like the `0xA00D`
  /// path). Adds integrated-scale weight, gravimetric flow and milk temp
  ///.
  MachineSnapshot _parseStateAndBengleShotSample(
    ByteData stateSample,
    ByteData shotSample,
    ByteData estimatorSample,
  ) {
    final state = De1StateEnum.fromHexValue(stateSample.getUint8(0));
    final subState =
        De1SubState.fromHexValue(stateSample.getUint8(1)) ??
        De1SubState.noState;
    final machineState = MachineStateSnapshot(
      state: mapDe1ToMachineState(state),
      substate: mapDe1SubToMachineSubstate(subState),
    );

    // Decode the latest fused-estimator frame (folded in via `withLatestFrom`
    // on the Bengle snapshot stream). `null` when no `[T]` has arrived (the
    // seed is a zero-length frame) or the wire sentinel says a field is
    // unobserved — either way the corresponding MachineSnapshot key stays
    // absent (nullable field -> omit-when-null).
    final est = parseBengleEstSample(estimatorSample);
    final double? fusedR1 = est?.r1;
    final double? fusedR2 = est?.r2;
    final double? fusedC = est?.c;
    final double? fusedConf = est?.confR;
    final double? vAbs = est?.vAbs;
    final double? estLag = est?.lag;
    final int? estFlags = est?.flags;
    // R1-collapse detector tail. Null on pre-Rev-2 frames (or field sentinels)
    // -> the snapshot keys stay absent.
    final int? detEventCount = est?.detEventCount;
    final double? detLastEventT = est?.detLastEventT;
    final double? detLastEventMag = est?.detLastEventMag;
    final double? detLastEventConc = est?.detLastEventConc;

    final s = parseBengleShotSample(shotSample);
    if (s == null) {
      // Truncated frame — the transport already drops these, so this
      // is defensive: emit a state-only snapshot rather than throw.
      return MachineSnapshot(
        timestamp: DateTime.now(),
        state: machineState,
        pressure: 0,
        flow: 0,
        mixTemperature: 0,
        groupTemperature: 0,
        targetMixTemperature: 0,
        targetGroupTemperature: 0,
        targetPressure: 0,
        targetFlow: 0,
        profileFrame: 0,
        steamTemperature: 0,
        fusedR1: fusedR1,
        fusedR2: fusedR2,
        fusedC: fusedC,
        fusedConf: fusedConf,
        vAbs: vAbs,
        estLag: estLag,
        estFlags: estFlags,
        detEventCount: detEventCount,
        detLastEventT: detLastEventT,
        detLastEventMag: detLastEventMag,
        detLastEventConc: detLastEventConc,
      );
    }

    return MachineSnapshot(
      timestamp: DateTime.now(),
      state: machineState,
      pressure: s.groupPressure,
      flow: s.groupFlow,
      mixTemperature: s.mixTemp,
      groupTemperature: s.headTemp,
      targetMixTemperature: s.setMixTemp,
      targetGroupTemperature: s.setHeadTemp,
      targetPressure: s.setGroupPressure,
      targetFlow: s.setGroupFlow,
      profileFrame: s.frameNumber,
      // MachineSnapshot.steamTemperature is an int; the 0xA013 value is
      // fractional (÷100). Rounding matches the whole-degree 0xA00D field and
      // keeps the shared type unchanged.
      steamTemperature: s.steamTemp.round(),
      weight: s.weight,
      weightFlow: s.gFlow,
      milkTemperature: s.milkTemp,
      fusedR1: fusedR1,
      fusedR2: fusedR2,
      fusedC: fusedC,
      fusedConf: fusedConf,
      vAbs: vAbs,
      estLag: estLag,
      estFlags: estFlags,
      detEventCount: detEventCount,
      detLastEventT: detLastEventT,
      detLastEventMag: detLastEventMag,
      detLastEventConc: detLastEventConc,
    );
  }

  De1WaterLevels _parseWaterLevels(ByteData data) {
    try {
      var waterlevel = data.getUint16(0, Endian.big);
      var waterThreshold = data.getUint16(2, Endian.big);

      return De1WaterLevels(
        currentLevel: waterlevel / 256.0,
        refillLevel: waterThreshold / 256.0,
      );
    } catch (e) {
      _log.severe("waternotify", e);
    }

    return De1WaterLevels(currentLevel: 0.0, refillLevel: 0.0);
  }

  De1ShotSettings _parseShotSettings(ByteData data) {
    var steamBits = data.getUint8(0);
    var targetSteamTemp = data.getUint8(1);
    var targetSteamLength = data.getUint8(2);
    var targetWaterTemp = data.getUint8(3);
    var targetWaterVolume = data.getUint8(4);
    var targetWaterLength = data.getUint8(5);
    var targetEspressoVolume = data.getUint8(6);
    var targetGroupTemp = data.getUint16(7) / (1 << 8);

    _log.info('SteamBits = ${steamBits.toRadixString(16)}');
    _log.info('TargetSteamTemp = $targetSteamTemp');
    _log.info('TargetSteamLength = $targetSteamLength');
    _log.info('TargetWaterTemp = $targetWaterTemp');
    _log.info('TargetWaterVolume = $targetWaterVolume');
    _log.info('TargetWaterLength = $targetWaterLength');
    _log.info('TargetEspressoVolume = $targetEspressoVolume');
    _log.info('TargetGroupTemp = $targetGroupTemp');

    return De1ShotSettings(
      steamSetting: steamBits,
      targetSteamTemp: targetSteamTemp,
      targetSteamDuration: targetSteamLength,
      targetHotWaterTemp: targetWaterTemp,
      targetHotWaterVolume: targetWaterVolume,
      targetHotWaterDuration: targetWaterLength,
      targetShotVolume: targetEspressoVolume,
      groupTemp: targetGroupTemp,
    );
  }
}
