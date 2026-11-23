import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart'
    show BengleMmr, BengleSteamMmr, MmrWriteBound, bengleWriteBound;
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart'
    show MMRItem;
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart'
    show MmrAddress, MmrValueKind;
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart'
    show BengleScaleMmr;
import 'package:yaml/yaml.dart';

import 'bengle_mmr_firmware_rows.dart';

const String _contractPath = 'assets/api/bengle_hw_v1.yml';

/// The contract_version this registration table was written against.
/// Bump deliberately, together with the enum updates the new contract needs.
const int _expectedContractVersion = 5;

const int _expectedRegisterCount = 62;

/// One app-declared register under test: the app enum entry and the FIRMWARE
/// register name of its row in bengle_hw_v1.yml.
class ContractEntry {
  const ContractEntry(this.register, this.contractName);

  final MmrAddress register;

  /// Firmware register name (the `name:` field of the contract row).
  final String contractName;

  String get label => '${register.runtimeType}.${register.name}';
}

const List<ContractEntry> entriesUnderTest = <ContractEntry>[
  ContractEntry(MMRItem.externalFlash, 'ExternalFlash'),
  ContractEntry(MMRItem.hwConfig, 'HWConfig'),
  ContractEntry(MMRItem.model, 'Model'),
  ContractEntry(MMRItem.cpuBoardModel, 'CPUBoardModel'),
  ContractEntry(MMRItem.v13Model, 'v13Model'),
  ContractEntry(MMRItem.cpuFirmwareBuild, 'CPUFirmwareBuild'),
  ContractEntry(MMRItem.debugLen, 'DebugLen'),
  ContractEntry(MMRItem.debugBuffer, 'DebugBuffer'),
  ContractEntry(MMRItem.debugConfig, 'DebugConfig'),
  ContractEntry(MMRItem.fanThreshold, 'FanThreshold'),
  ContractEntry(MMRItem.tankTemp, 'TankTemp'),
  ContractEntry(MMRItem.heaterUp1Flow, 'HeaterUp1Flow'),
  ContractEntry(MMRItem.heaterUp2Flow, 'HeaterUp2Flow'),
  ContractEntry(MMRItem.waterHeaterIdleTemp, 'WaterHeaterIdleTemp'),
  ContractEntry(MMRItem.ghcInfo, 'GHCInfo'),
  ContractEntry(MMRItem.targetSteamFlow, 'TargetSteamFlow'),
  ContractEntry(MMRItem.steamStartSecs, 'SteamStartSecs'),
  ContractEntry(MMRItem.serialN, 'SerialN'),
  ContractEntry(MMRItem.heaterV, 'HeaterV'),
  ContractEntry(MMRItem.heaterUp2Timeout, 'HeaterUp2Timeout'),
  ContractEntry(MMRItem.calFlowEst, 'CalFlowEst'),
  ContractEntry(MMRItem.flushFlowRate, 'FlushFlowRate'),
  ContractEntry(MMRItem.flushTemp, 'FlushTemp'),
  ContractEntry(MMRItem.flushTimeout, 'FlushTimeout'),
  ContractEntry(MMRItem.hotWaterFlowRate, 'HotWaterFlowRate'),
  ContractEntry(MMRItem.steamPurgeMode, 'SteamPurgeMode'),
  ContractEntry(MMRItem.allowUSBCharging, 'AllowUSBCharging'),
  ContractEntry(MMRItem.appFeatureFlags, 'AppFeatureFlags'),
  ContractEntry(MMRItem.refillKitPresent, 'RefillKitPresent'),
  ContractEntry(MMRItem.userPresent, 'UserPresent'),
  ContractEntry(MMRItem.profileModeCaps, 'ProfileModeCaps'),
  ContractEntry(MMRItem.nativeShapeLatched, 'NativeShapeLatched'),
  ContractEntry(BengleScaleMmr.endOfShotWeight, 'EndOfShotWeight'),
  ContractEntry(BengleScaleMmr.scaleTare, 'ScaleTare'),
  ContractEntry(BengleMmr.matSetPoint, 'MatSetPoint'),
  ContractEntry(BengleMmr.scaleCalCmd, 'ScaleCalCmd'),
  ContractEntry(BengleMmr.scaleCalState, 'ScaleCalState'),
  ContractEntry(BengleMmr.scaleCalWeight, 'ScaleCalWeight'),
  ContractEntry(BengleMmr.frontLedColor, 'FrontLEDColor'),
  ContractEntry(BengleMmr.rearLedColor, 'RearLEDColor'),
  ContractEntry(BengleMmr.frontLedAwake, 'FrontLEDAwake'),
  ContractEntry(BengleMmr.rearLedAwake, 'RearLEDAwake'),
  ContractEntry(BengleMmr.frontLedSleep, 'FrontLEDSleep'),
  ContractEntry(BengleMmr.rearLedSleep, 'RearLEDSleep'),
  ContractEntry(BengleMmr.cupWarmerMode, 'CupWarmerMode'),
  ContractEntry(BengleMmr.inactivitySleepTimeout, 'InactivitySleepTimeout'),
  ContractEntry(BengleMmr.setLocalTimeOfWeek, 'SetLocalTimeOfWeek'),
  ContractEntry(BengleMmr.scheduleEntry, 'ScheduleEntry'),
  ContractEntry(BengleMmr.scheduleControl, 'ScheduleControl'),
  ContractEntry(BengleMmr.matCurrentTemp, 'MatCurrentTemp'),
  ContractEntry(BengleMmr.matPreheatEnable, 'MatPreheatEnable'),
  ContractEntry(BengleMmr.matPreheatLeadMin, 'MatPreheatLeadMin'),
  ContractEntry(BengleMmr.matPreheatActive, 'MatPreheatActive'),
  ContractEntry(BengleSteamMmr.targetMilkTemp, 'TargetMilkTemp'),
];

class ContractRegister {
  const ContractRegister({
    required this.name,
    required this.fwRow,
    required this.address,
    required this.length,
    required this.perms,
    required this.mult,
    required this.valueKind,
    required this.unit,
    required this.min,
    required this.max,
    required this.appAlias,
    this.hasEffectiveBound = false,
    this.effectiveMin,
    this.effectiveMax,
  });

  final String name;
  final int? fwRow;
  final int address;
  final int length;
  final String perms;
  final int mult;
  final String valueKind;
  final String? unit;
  final int? min;
  final int? max;
  final String? appAlias;
  final bool hasEffectiveBound;
  final int? effectiveMin;
  final int? effectiveMax;

  bool get writable => perms.contains('W');
}

class HwContract {
  const HwContract({
    required this.contractVersion,
    required this.firmwareCommit,
    required this.rows,
    required this.registers,
  });

  final int contractVersion;
  final String firmwareCommit;

  final List<ContractRegister> rows;

  /// Keyed by firmware register name.
  final Map<String, ContractRegister> registers;
}

int? _intOrNull(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  final t = value.toString().trim();
  if (t.startsWith('0x') || t.startsWith('0X')) {
    return int.parse(t.substring(2), radix: 16);
  }
  return int.parse(t);
}

ContractRegister _register(YamlMap fields) {
  final name =
      fields['name'] as String? ??
      (throw const FormatException('register row without a name'));
  return ContractRegister(
    name: name,
    fwRow: _intOrNull(fields['fw_row']),
    address:
        _intOrNull(fields['address']) ??
        (throw FormatException('register $name has no address')),
    length:
        _intOrNull(fields['length']) ??
        (throw FormatException('register $name has no length')),
    perms: fields['perms']?.toString() ?? '',
    mult:
        _intOrNull(fields['mult']) ??
        (throw FormatException('register $name has no mult')),
    valueKind: fields['value_kind']?.toString() ?? '',
    unit: fields['unit']?.toString(),
    min: _intOrNull(fields['min']),
    max: _intOrNull(fields['max']),
    appAlias: fields['app_alias']?.toString(),
    hasEffectiveBound:
        fields.containsKey('effective_min') &&
        fields.containsKey('effective_max'),
    effectiveMin: _intOrNull(fields['effective_min']),
    effectiveMax: _intOrNull(fields['effective_max']),
  );
}

const Map<String, String> boundExceptions = <String, String>{
  'ExternalFlash': 'byte window to external flash, not a scalar',
  'HeaterV':
      'the firmware takes only 120 or 230; a clamp would turn unset into a '
      'set voltage',
  'CalFlowEst': 'the firmware ignores the write at the pin',
  'SetLCZero': 'trigger, the written value is ignored',
  'SetLCCalPoint1': 'retired trigger, the written value is ignored',
  'SetLCCalPoint2': 'retired trigger, the written value is ignored',
  'ScaleTare': 'trigger, the written value is ignored',
};

const Map<String, String> writableRowsWithoutAppEntry = <String, String>{
  'V24CurrentBudget':
      'the app does not write it; an app entry must clamp to the effective '
      'range',
  'SetLCZero': 'trigger the app does not send',
  'SetLCCalPoint1': 'retired trigger the app does not send',
  'SetLCCalPoint2': 'retired trigger the app does not send',
};

List<String> unconsumedWritableProblems(
  HwContract contract,
  List<ContractEntry> entries,
  Map<String, String> gaps,
) {
  final covered = entries.map((e) => e.contractName).toSet();
  final actual = {
    for (final row in contract.rows)
      if (row.writable && !covered.contains(row.name)) row.name,
  };
  return [
    for (final name in actual.difference(gaps.keys.toSet()))
      'writable row $name has no app entry and is not a named gap',
    for (final name in gaps.keys.toSet().difference(actual))
      'named gap $name is not an unconsumed writable row',
  ]..sort();
}

List<String> effectiveBoundProblems(
  HwContract contract,
  List<ContractEntry> entries,
  Map<String, String> exceptions, {
  MmrWriteBound Function(MmrAddress) appBound = bengleWriteBound,
}) {
  final problems = <String>[];
  for (final row in contract.rows) {
    final name = row.name;
    if (!row.writable) {
      if (row.hasEffectiveBound) {
        problems.add('$name is not writable but carries an effective bound');
      }
      continue;
    }
    if (!row.hasEffectiveBound) {
      problems.add('$name is writable and has no effective_min/effective_max');
      continue;
    }
    final lo = row.effectiveMin;
    final hi = row.effectiveMax;
    if ((lo == null) != (hi == null)) {
      problems.add('$name has only one effective bound');
      continue;
    }
    if (lo == null || hi == null) {
      if (!exceptions.containsKey(name)) {
        problems.add(
          '$name has no effective range and is not a named exception',
        );
      }
      continue;
    }
    if (exceptions.containsKey(name)) {
      problems.add('$name is a named exception but has an effective range');
    }
    if (lo > hi) {
      problems.add('$name effective range $lo..$hi is empty');
    }
    if (row.min != null && lo < row.min!) {
      problems.add('$name effective_min $lo lies below the column ${row.min}');
    }
    if (row.max != null && hi > row.max!) {
      problems.add('$name effective_max $hi lies above the column ${row.max}');
    }
  }
  for (final name in exceptions.keys) {
    final row = contract.registers[name];
    if (row == null || !row.writable) {
      problems.add('named exception $name is not a writable contract row');
    }
  }
  for (final entry in entries) {
    final row = contract.registers[entry.contractName];
    if (row == null || !row.writable) continue;
    final lo = row.effectiveMin;
    final hi = row.effectiveMax;
    if (lo == null || hi == null) continue;
    final app = appBound(entry.register);
    if (app.min == null || app.max == null) {
      problems.add(
        '${entry.label} has app bounds [${app.min}..${app.max}] but '
        '${row.name} has the effective range $lo..$hi: both app bounds are '
        'required',
      );
      continue;
    }
    if (app.min != lo || app.max != hi) {
      problems.add(
        '${entry.label} app bounds [${app.min}..${app.max}] differ from the '
        'effective range $lo..$hi of ${row.name}',
      );
    }
  }
  return problems;
}

HwContract parseBengleHwContract(String text) {
  final doc = loadYaml(text);
  if (doc is! YamlMap) {
    throw const FormatException('the contract is not a YAML mapping');
  }
  final version = _intOrNull(doc['contract_version']);
  if (version == null) {
    throw const FormatException('contract_version missing from contract');
  }
  final firmware = doc['firmware'];
  final commit = firmware is YamlMap ? firmware['commit']?.toString() : null;
  if (commit == null) {
    throw const FormatException('firmware.commit missing from contract');
  }
  final rows = doc['registers'];
  if (rows is! YamlList || rows.isEmpty) {
    throw const FormatException('no registers parsed from contract');
  }
  final physical = [for (final row in rows) _register(row as YamlMap)];
  final registers = <String, ContractRegister>{};
  for (final register in physical) {
    if (registers.containsKey(register.name)) {
      throw FormatException('duplicate register name ${register.name}');
    }
    registers[register.name] = register;
  }
  return HwContract(
    contractVersion: version,
    firmwareCommit: commit,
    rows: List.unmodifiable(physical),
    registers: registers,
  );
}

HwContract? _cached;
HwContract _contract() =>
    _cached ??= parseBengleHwContract(File(_contractPath).readAsStringSync());

String _hex(int value) =>
    '0x${value.toRadixString(16).toUpperCase().padLeft(8, '0')}';

bool _appKindReads(MmrValueKind app, String contract) =>
    app.name == contract ||
    (app == MmrValueKind.int32 && contract == MmrValueKind.boolean.name);

void main() {
  group('bengle_hw_v1.yml', () {
    test('parses, pins a firmware commit, and matches the checker version', () {
      final c = _contract();
      expect(
        c.contractVersion,
        _expectedContractVersion,
        reason:
            'contract_version drift: the contract file is '
            'v${c.contractVersion} but this registration table was written '
            'against v$_expectedContractVersion. Update the enums against the '
            'new contract, then bump _expectedContractVersion deliberately.',
      );
      expect(
        c.firmwareCommit,
        hasLength(40),
        reason: 'firmware.commit must pin a full 40-char firmware SHA',
      );
      stdout.writeln(
        '  contract v${c.contractVersion}, firmware pin ${c.firmwareCommit}, '
        '${c.registers.length} contract rows, '
        '${entriesUnderTest.length} app registers under test',
      );
    });

    test('refuses a duplicated register name', () {
      const twice = '''
contract_version: 1
firmware:
  commit: "0000000000000000000000000000000000000000"
registers:
  - name: A
    address: "0x00800000"
    length: 4
    mult: 1
  - name: A
    address: "0x00800004"
    length: 4
    mult: 1
''';
      expect(
        () => parseBengleHwContract(twice),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('duplicate register name A'),
          ),
        ),
      );
    });

    test('every registered app enum value is under test', () {
      final declared = <MmrAddress>{
        ...MMRItem.values,
        ...BengleMmr.values,
        ...BengleSteamMmr.values,
        ...BengleScaleMmr.values,
      };
      final registered = entriesUnderTest.map((e) => e.register).toSet();
      String labels(Iterable<MmrAddress> values) =>
          values.map((v) => '${v.runtimeType}.${(v as Enum).name}').join(', ');
      expect(
        labels(declared.difference(registered)),
        isEmpty,
        reason: 'declared MMR registers missing from entriesUnderTest',
      );
      expect(
        labels(registered.difference(declared)),
        isEmpty,
        reason: 'entriesUnderTest holds a register outside the four enums',
      );
    });

    test('every app register maps to a distinct contract row', () {
      final names = entriesUnderTest.map((e) => e.contractName).toList();
      expect(
        names.toSet().length,
        names.length,
        reason: 'two registration entries claim the same contract row',
      );
      final registers = entriesUnderTest.map((e) => e.register).toList();
      expect(
        registers.toSet().length,
        registers.length,
        reason: 'an app register is registered twice',
      );
    });
  });

  group('contract_version 3 refresh', () {
    test('holds every reachable firmware row', () {
      final c = _contract();
      expect(
        c.rows.length,
        _expectedRegisterCount,
        reason:
            'REGISTER COUNT drift: the contract has ${c.rows.length} '
            'rows, expected $_expectedRegisterCount',
      );
    });

    test('gives every row its own address', () {
      final seen = <int, String>{};
      final clashes = <String>[];
      for (final row in _contract().rows) {
        final other = seen[row.address];
        if (other != null) {
          clashes.add('${_hex(row.address)}: $other and ${row.name}');
        }
        seen[row.address] = row.name;
      }
      expect(clashes, isEmpty, reason: 'ADDRESS clash in $_contractPath');
    });
  });

  group('contract rows match the firmware fixture', () {
    test('pins the firmware commit of the fixture', () {
      expect(_contract().firmwareCommit, firmwareRowsCommit);
    });

    test('holds the same row names as the fixture', () {
      final contractNames = _contract().rows.map((r) => r.name).toSet();
      final fixtureNames = firmwareRows.map((r) => r.name).toSet();
      expect(
        contractNames.difference(fixtureNames),
        isEmpty,
        reason: 'contract rows absent from the firmware fixture',
      );
      expect(
        fixtureNames.difference(contractNames),
        isEmpty,
        reason: 'firmware fixture rows absent from the contract',
      );
    });

    for (final fw in firmwareRows) {
      test('${fw.name} matches firmware row ${fw.fwRow}', () {
        final row = _contract().registers[fw.name];
        expect(row, isNotNull, reason: 'row ${fw.name} is missing');
        expect(row!.fwRow, fw.fwRow, reason: 'FW_ROW drift on ${fw.name}');
        expect(
          _hex(row.address),
          _hex(fw.address),
          reason: 'ADDRESS drift on contract row ${fw.name}',
        );
        expect(
          row.length,
          fw.length,
          reason: 'LENGTH drift on contract row ${fw.name}',
        );
        expect(
          row.perms,
          fw.perms,
          reason: 'PERMS drift on contract row ${fw.name}',
        );
        expect(
          row.mult,
          fw.mult,
          reason: 'MULT drift on contract row ${fw.name}',
        );
        expect(
          row.valueKind,
          fw.valueKind,
          reason: 'VALUE_KIND drift on contract row ${fw.name}',
        );
        expect(
          row.unit,
          fw.unit,
          reason: 'UNIT drift on contract row ${fw.name}',
        );
        expect(
          (row.min ?? 0) < 0,
          fw.signed,
          reason: 'SIGN drift on contract row ${fw.name}: min ${row.min}',
        );
      });
    }
  });

  group('app register matches contract (address/length/scale/range)', () {
    for (final entry in entriesUnderTest) {
      test('${entry.label} <-> ${entry.contractName}', () {
        final row = _contract().registers[entry.contractName];
        expect(
          row,
          isNotNull,
          reason:
              'app register ${entry.label} is missing from the contract: '
              'no row named "${entry.contractName}" in $_contractPath. Every '
              'app-declared register must exist in the contract.',
        );
        final contract = row!;
        final app = entry.register;

        expect(
          _hex(app.address),
          _hex(contract.address),
          reason:
              'ADDRESS drift on ${entry.label}: app ${_hex(app.address)} '
              'vs contract ${_hex(contract.address)}',
        );
        expect(
          app.length,
          contract.length,
          reason:
              'LENGTH drift on ${entry.label}: app ${app.length} vs '
              'contract ${contract.length}',
        );

        expect(
          _appKindReads(app.kind, contract.valueKind),
          isTrue,
          reason:
              'VALUE_KIND drift on ${entry.label}: app ${app.kind.name} vs '
              'contract ${contract.valueKind}',
        );

        expect(
          app.writeScale,
          contract.mult.toDouble(),
          reason:
              'SCALE drift on ${entry.label}: app writeScale '
              '${app.writeScale} vs contract mult ${contract.mult} '
              '(wire value = engineering value x mult)',
        );
        expect(
          app.readScale,
          closeTo(1.0 / contract.mult, 1e-9),
          reason:
              'SCALE drift on ${entry.label}: app readScale '
              '${app.readScale} vs contract 1/mult '
              '(${1.0 / contract.mult})',
        );

        final appMin = bengleWriteBound(app).min;
        final appMax = bengleWriteBound(app).max;
        if (appMin != null && contract.min != null) {
          expect(
            appMin >= contract.min!,
            isTrue,
            reason:
                'RANGE drift on ${entry.label}: app min $appMin lies '
                'below contract min ${contract.min} (app range must be a '
                'subset of the contract range)',
          );
        }
        if (appMax != null && contract.max != null) {
          expect(
            appMax <= contract.max!,
            isTrue,
            reason:
                'RANGE drift on ${entry.label}: app max $appMax lies '
                'above contract max ${contract.max} (app range must be a '
                'subset of the contract range)',
          );
        }
      });
    }
  });

  group('effective write bounds', () {
    test('every writable row and every app bound agree', () {
      expect(
        effectiveBoundProblems(_contract(), entriesUnderTest, boundExceptions),
        isEmpty,
      );
    });

    test('every writable row has an app entry or is a named gap', () {
      expect(
        unconsumedWritableProblems(
          _contract(),
          entriesUnderTest,
          writableRowsWithoutAppEntry,
        ),
        isEmpty,
      );
    });

    test('dropping the app entry of a bounded row fails', () {
      final without = [
        for (final e in entriesUnderTest)
          if (e.contractName != 'MatSetPoint') e,
      ];
      expect(
        unconsumedWritableProblems(
          _contract(),
          without,
          writableRowsWithoutAppEntry,
        ),
        ['writable row MatSetPoint has no app entry and is not a named gap'],
      );
    });

    test('removing either bound of MatSetPoint fails', () {
      const row = BengleMmr.matSetPoint;
      for (final bounds in const [(null, 80), (0, null)]) {
        final problems = effectiveBoundProblems(_contract(), [
          ContractEntry(
            _FakeAddress(row.address, min: bounds.$1, max: bounds.$2),
            'MatSetPoint',
          ),
        ], boundExceptions);
        expect(problems, [contains('both app bounds are required')]);
      }
    });

    test('an app bound wider than the effective bound fails', () {
      final problems = effectiveBoundProblems(_contract(), [
        ContractEntry(
          _FakeAddress(
            BengleScaleMmr.endOfShotWeight.address,
            min: 0,
            max: 1000000,
          ),
          'EndOfShotWeight',
        ),
      ], boundExceptions);
      expect(problems, [contains('differ from the effective range 0..300000')]);
    });

    test('a register with no app bounds and a finite range fails', () {
      final problems = effectiveBoundProblems(
        parseBengleHwContract(_synthetic(effective: '0', max: '5')),
        [ContractEntry(_FakeAddress(0x00800000), 'A')],
        const {},
      );
      expect(problems, [contains('both app bounds are required')]);
    });

    test('a writable row without effective keys fails', () {
      final problems = effectiveBoundProblems(
        parseBengleHwContract(_synthetic(keys: false)),
        const [],
        const {},
      );
      expect(problems, [contains('has no effective_min/effective_max')]);
    });

    test('a null effective range needs a named exception', () {
      final contract = parseBengleHwContract(
        _synthetic(effective: 'null', max: 'null'),
      );
      expect(effectiveBoundProblems(contract, const [], const {}), [
        contains('is not a named exception'),
      ]);
      expect(
        effectiveBoundProblems(contract, const [], const {'A': 'trigger'}),
        isEmpty,
      );
    });

    test('a named exception with a finite range fails', () {
      final problems = effectiveBoundProblems(
        parseBengleHwContract(_synthetic(effective: '0', max: '5')),
        const [],
        const {'A': 'trigger'},
      );
      expect(problems, [contains('named exception but has an effective')]);
    });

    test('an effective bound outside the column fails', () {
      final problems = effectiveBoundProblems(
        parseBengleHwContract(_synthetic(effective: '0', max: '20')),
        const [],
        const {},
      );
      expect(problems, [contains('lies above the column 10')]);
    });

    test('dropping the effective bound of one real row fails', () {
      final contract = parseBengleHwContract(
        _editRow(
          'MatSetPoint',
          (block) => block
              .replaceFirst(RegExp(r'\n    effective_min: [^\n]*'), '')
              .replaceFirst(RegExp(r'\n    effective_max: [^\n]*'), ''),
        ),
      );
      expect(
        effectiveBoundProblems(contract, entriesUnderTest, boundExceptions),
        ['MatSetPoint is writable and has no effective_min/effective_max'],
      );
    });

    test('a changed effective bound of one real row fails', () {
      final contract = parseBengleHwContract(
        _editRow(
          'TankTemp',
          (block) =>
              block.replaceFirst('effective_max: 60', 'effective_max: 59'),
        ),
      );
      expect(
        effectiveBoundProblems(contract, entriesUnderTest, boundExceptions),
        [contains('differ from the effective range 0..59 of TankTemp')],
      );
    });

    test('AppFeatureFlags is bounded to the exact float range', () {
      final row = _contract().registers['AppFeatureFlags']!;
      expect([row.effectiveMin, row.effectiveMax], [0, 16777215]);
      expect(
        [
          bengleWriteBound(MMRItem.appFeatureFlags).min,
          bengleWriteBound(MMRItem.appFeatureFlags).max,
        ],
        [0, 16777215],
      );
    });

    test('an AppFeatureFlags effective_max of 2147483647 fails', () {
      final contract = parseBengleHwContract(
        _editRow(
          'AppFeatureFlags',
          (block) => block.replaceFirst(
            'effective_max: 16777215',
            'effective_max: 2147483647',
          ),
        ),
      );
      expect(
        effectiveBoundProblems(contract, entriesUnderTest, boundExceptions),
        [contains('differ from the effective range 0..2147483647')],
      );
    });

    test('an AppFeatureFlags app clamp of 0x7FFFFFFF fails', () {
      final problems = effectiveBoundProblems(_contract(), [
        ContractEntry(
          _FakeAddress(
            MMRItem.appFeatureFlags.address,
            min: 0,
            max: 0x7FFFFFFF,
          ),
          'AppFeatureFlags',
        ),
      ], boundExceptions);
      expect(problems, [
        contains('differ from the effective range 0..16777215'),
      ]);
    });

    test('the checker compares the Bengle bound, not the MMRItem bound', () {
      expect([MMRItem.tankTemp.min, MMRItem.tankTemp.max], [null, null]);
      expect(
        effectiveBoundProblems(_contract(), entriesUnderTest, boundExceptions),
        isEmpty,
      );
      final problems = effectiveBoundProblems(
        _contract(),
        entriesUnderTest,
        boundExceptions,
        appBound: (address) => address == MMRItem.tankTemp
            ? (min: 0, max: 59)
            : bengleWriteBound(address),
      );
      expect(problems, [
        contains('app bounds [0..59] differ from the effective range 0..60'),
      ]);
    });

    test('every named exception is a writable contract row', () {
      final problems = effectiveBoundProblems(_contract(), const [], const {
        ...boundExceptions,
        'HWConfig': 'read-only',
      });
      expect(problems, [contains('named exception HWConfig')]);
    });
  });

  group('contract coverage (informational, never fails)', () {
    test('contract rows not yet consumed by the app', () {
      final covered = entriesUnderTest.map((e) => e.contractName).toSet();
      final unconsumed =
          _contract().registers.values
              .where((r) => !covered.contains(r.name))
              .toList()
            ..sort((a, b) => (a.fwRow ?? -1).compareTo(b.fwRow ?? -1));
      stdout.writeln(
        '  ${unconsumed.length} contract rows have no app entry '
        '(legal -- the app grows into the contract):',
      );
      for (final r in unconsumed) {
        stdout.writeln(
          '    row ${r.fwRow} ${r.name} @ ${_hex(r.address)} '
          '(${r.perms}, mult ${r.mult})',
        );
      }
    });

    test('contract rows carrying an app_alias (desc differs from FW name)', () {
      for (final r in _contract().registers.values) {
        if (r.appAlias != null) {
          stdout.writeln(
            '    ${r.name}: app declares desc "${r.appAlias}" (documented '
            'alias, not drift)',
          );
        }
      }
    });

    test('app ranges strictly narrower than the contract (legal)', () {
      for (final entry in entriesUnderTest) {
        final row = _contract().registers[entry.contractName];
        if (row == null) continue;
        final app = bengleWriteBound(entry.register);
        final narrowerMin =
            app.min != null && row.min != null && app.min! > row.min!;
        final narrowerMax =
            app.max != null && row.max != null && app.max! < row.max!;
        if (narrowerMin || narrowerMax) {
          stdout.writeln(
            '    ${entry.label}: app [${app.min}..${app.max}] inside '
            'contract [${row.min}..${row.max}]',
          );
        }
      }
    });
  });
}

class _FakeAddress extends MmrAddress {
  _FakeAddress(this.address, {this.min, this.max});

  @override
  final int address;
  @override
  final int? min;
  @override
  final int? max;
  @override
  int get length => 4;
  @override
  String get name => 'fake';
  @override
  MmrValueKind get kind => MmrValueKind.int32;
}

String _editRow(String name, String Function(String block) edit) {
  final text = File(_contractPath).readAsStringSync();
  final start = text.indexOf('\n  - name: $name\n');
  expect(start, isNonNegative, reason: 'row $name not in the contract');
  final next = text.indexOf('\n  - name: ', start + 1);
  final end = next < 0 ? text.length : next;
  final block = text.substring(start, end);
  final edited = edit(block);
  expect(edited, isNot(block), reason: 'the edit changed nothing in $name');
  return text.replaceRange(start, end, edited);
}

String _synthetic({
  bool keys = true,
  String effective = '0',
  String max = '5',
}) {
  final bound = keys
      ? '''
    effective_min: $effective
    effective_max: $max
'''
      : '';
  return '''
contract_version: 4
firmware:
  commit: "0000000000000000000000000000000000000000"
registers:
  - name: A
    address: "0x00800000"
    length: 4
    perms: RW
    mult: 1
    min: 0
    max: 10
$bound''';
}
