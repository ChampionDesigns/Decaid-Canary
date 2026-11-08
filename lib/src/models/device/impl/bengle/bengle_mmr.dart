import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';

typedef MmrWriteBound = ({int? min, int? max});

const Map<MMRItem, MmrWriteBound> bengleMmrItemBounds = {
  MMRItem.tankTemp: (min: 0, max: 60),
  MMRItem.heaterUp1Flow: (min: 5, max: 80),
  MMRItem.heaterUp2Flow: (min: 5, max: 80),
  MMRItem.waterHeaterIdleTemp: (min: 5, max: 1000),
  MMRItem.targetSteamFlow: (min: 40, max: 400),
  MMRItem.steamStartSecs: (min: 10, max: 400),
  MMRItem.heaterUp2Timeout: (min: 5, max: 300),
  MMRItem.flushFlowRate: (min: 10, max: 80),
  MMRItem.flushTemp: (min: 10, max: 990),
  MMRItem.flushTimeout: (min: 10, max: 2500),
  MMRItem.hotWaterFlowRate: (min: 0, max: 80),
  MMRItem.steamPurgeMode: (min: 0, max: 1),
  MMRItem.allowUSBCharging: (min: 0, max: 1),
  MMRItem.appFeatureFlags: (min: 0, max: 0xFFFFFF),
  MMRItem.refillKitPresent: (min: 0, max: 2),
  MMRItem.userPresent: (min: 0, max: 1),
};

MmrWriteBound bengleWriteBound(MmrAddress address) =>
    (address is MMRItem ? bengleMmrItemBounds[address] : null) ??
    (min: address.min, max: address.max);

enum BengleMmr implements MmrAddress {
  matSetPoint(
    0x00803874,
    4,
    MmrValueKind.scaledFloat,
    'MatSetPoint',
    min: 0,
    max: 80,
    readScale: 1.0,
    writeScale: 1.0,
  ),

  scaleCalCmd(0x00803880, 4, MmrValueKind.int32, 'ScaleCalCmd', min: 0, max: 3),
  scaleCalState(0x00803884, 4, MmrValueKind.int32, 'ScaleCalState'),
  scaleCalWeight(
    0x00803888,
    4,
    MmrValueKind.scaledFloat,
    'ScaleCalWeight',
    min: 10,
    max: 100000,
    readScale: 0.1,
    writeScale: 10.0,
  ),

  frontLedColor(
    0x00803890,
    4,
    MmrValueKind.int32,
    'FrontLEDColor',
    min: 0,
    max: 0xFFFFFF,
  ),

  rearLedColor(
    0x00803894,
    4,
    MmrValueKind.int32,
    'RearLEDColor',
    min: 0,
    max: 0xFFFFFF,
  ),

  frontLedAwake(
    0x00803898,
    4,
    MmrValueKind.int32,
    'FrontLEDAwake',
    min: 0,
    max: 0xFFFFFF,
  ),
  rearLedAwake(
    0x0080389C,
    4,
    MmrValueKind.int32,
    'RearLEDAwake',
    min: 0,
    max: 0xFFFFFF,
  ),
  frontLedSleep(
    0x008038A0,
    4,
    MmrValueKind.int32,
    'FrontLEDSleep',
    min: 0,
    max: 0xFFFFFF,
  ),
  rearLedSleep(
    0x008038A4,
    4,
    MmrValueKind.int32,
    'RearLEDSleep',
    min: 0,
    max: 0xFFFFFF,
  ),

  cupWarmerMode(
    0x008038AC,
    4,
    MmrValueKind.int32,
    'CupWarmerMode',
    min: 0,
    max: 1,
  ),

  inactivitySleepTimeout(
    0x008038BC,
    4,
    MmrValueKind.int32,
    'InactivitySleepTimeout',
    min: 0,
    max: 240,
  ),

  setLocalTimeOfWeek(
    0x008038C0,
    4,
    MmrValueKind.int32,
    'SetLocalTimeOfWeek',
    min: 0,
    max: 604799,
  ),
  scheduleEntry(
    0x008038C4,
    4,
    MmrValueKind.int32,
    'ScheduleEntry',
    min: 0,
    max: 0x7FFFFFFF,
  ),
  scheduleControl(
    0x008038C8,
    4,
    MmrValueKind.int32,
    'ScheduleControl',
    min: 0,
    max: 255,
  ),

  matCurrentTemp(
    0x008038CC,
    4,
    MmrValueKind.scaledFloat,
    'MatCurrentTemp',
    min: 0,
    max: 1600,
    readScale: 0.1,
    writeScale: 10.0,
  ),

  matPreheatEnable(
    0x008038D0,
    4,
    MmrValueKind.int32,
    'MatPreheatEnable',
    min: 0,
    max: 1,
  ),
  matPreheatLeadMin(
    0x008038D4,
    4,
    MmrValueKind.int32,
    'MatPreheatLeadMin',
    min: 0,
    max: 120,
  ),
  matPreheatActive(
    0x008038D8,
    4,
    MmrValueKind.int32,
    'MatPreheatActive',
    min: 0,
    max: 1,
  );

  const BengleMmr(
    this.address,
    this.length,
    this.kind,
    this.description, {
    this.readScale = 1.0,
    this.writeScale = 1.0,
    this.min,
    this.max,
  });

  @override
  final int address;
  @override
  final int length;
  @override
  final MmrValueKind kind;
  final String description;
  @override
  final double readScale;
  @override
  final double writeScale;
  @override
  final int? min;
  @override
  final int? max;

  @override
  String get name => (this as Enum).name;
}

enum BengleSteamMmr implements MmrAddress {
  targetMilkTemp(
    0x008038A8,
    4,
    MmrValueKind.scaledFloat,
    'TargetMilkTemp',
    min: 0,
    max: 850,
    readScale: 0.1,
    writeScale: 10.0,
  );

  const BengleSteamMmr(
    this.address,
    this.length,
    this.kind,
    this.description, {
    this.readScale = 1.0,
    this.writeScale = 1.0,
    this.min,
    this.max,
  });

  @override
  final int address;
  @override
  final int length;
  @override
  final MmrValueKind kind;
  final String description;
  @override
  final double readScale;
  @override
  final double writeScale;
  @override
  final int? min;
  @override
  final int? max;

  @override
  String get name => (this as Enum).name;
}
