import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/firmware_wake_entry.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';
import 'package:reaprime/src/models/wake_schedule.dart';

import '../../helpers/fake_ble_transport.dart';

int _storedByFirmware(int packed) =>
    Float32List.fromList([packed.toDouble()])[0].toInt();

FirmwareWakeWindow _decode(int packed) => FirmwareWakeWindow(
  dow: packed >> 22,
  startMin: (packed >> 11) & 0x7FF,
  endMin: packed & 0x7FF,
);

List<int> _mmrWritesTo(FakeBleTransport transport, int address) {
  return [
    for (final entry in transport.writes)
      if (entry.characteristicUUID == Endpoint.writeToMMR.uuid &&
          entry.data[1] == (address >> 16) & 0xFF &&
          entry.data[2] == (address >> 8) & 0xFF &&
          entry.data[3] == address & 0xFF)
        ByteData.sublistView(
          Uint8List.fromList(entry.data.sublist(4, 8)),
        ).getUint32(0, Endian.little),
  ];
}

Future<Bengle> _connectedBengle(FakeBleTransport transport) async {
  transport
    ..queueOnConnectResponses(v13Model: 128)
    ..queuePaletteHydrationResponses();
  final bengle = Bengle(transport: transport);
  await bengle.onConnect();
  addTearDown(bengle.dispose);
  transport.writes.clear();
  return bengle;
}

void main() {
  group('firmwareStorableWakeWindow', () {
    test('the Codex example: Thursday 07:00-07:01 packs to an unstorable '
        'value without the policy', () {
      const window = FirmwareWakeWindow(dow: 4, startMin: 420, endMin: 421);
      expect(window.pack(), 17637797);
      expect(_storedByFirmware(window.pack()), 17637796);
      expect(_decode(_storedByFirmware(window.pack())).endMin, 420);
    });

    test('the Codex example becomes Thursday 07:00-07:02', () {
      const window = FirmwareWakeWindow(dow: 4, startMin: 420, endMin: 421);
      final sent = firmwareStorableWakeWindow(window);
      expect(
        sent,
        const FirmwareWakeWindow(dow: 4, startMin: 420, endMin: 422),
      );
      expect(sent.pack(), 17637798);
      expect(_storedByFirmware(sent.pack()), sent.pack());
    });

    test('every window for dow 0 to 6 and end 0 to $kFirmwareWakeMaxEndMin '
        'is stored exactly or refused', () {
      var sentCount = 0;
      var refusedCount = 0;
      for (var dow = 0; dow <= 6; dow++) {
        for (var end = 0; end <= kFirmwareWakeMaxEndMin; end++) {
          for (final start in {0, end - 1, end - 2, 420}) {
            if (start < 0) continue;
            final window = FirmwareWakeWindow(
              dow: dow,
              startMin: start,
              endMin: end,
            );
            final FirmwareWakeWindow sent;
            try {
              sent = firmwareStorableWakeWindow(window);
            } on UnstorableWakeWindowException catch (e) {
              expect(e.window, window);
              refusedCount++;
              continue;
            }
            sentCount++;
            final packed = sent.pack();
            expect(_storedByFirmware(packed), packed, reason: '$window');
            final stored = _decode(_storedByFirmware(packed));
            expect(stored, sent, reason: '$window');
            expect(stored.dow, dow);
            expect(stored.startMin, start);
            expect(stored.startMin < stored.endMin, isTrue, reason: '$window');
            expect(stored.endMin <= kFirmwareWakeMaxEndMin, isTrue);
            expect((stored.endMin - end).abs() <= 1, isTrue, reason: '$window');
            if (dow <= 3) {
              expect(sent, window, reason: '$window');
            } else if (end.isEven) {
              expect(sent, window, reason: '$window');
            } else {
              expect(stored.endMin, end + 1, reason: '$window');
            }
          }
        }
      }
      expect(sentCount, greaterThan(0));
      expect(refusedCount, greaterThan(0));
    });

    test('a window that is empty is refused', () {
      for (final window in const [
        FirmwareWakeWindow(dow: 4, startMin: 1440, endMin: 1441),
        FirmwareWakeWindow(dow: 5, startMin: 600, endMin: 600),
        FirmwareWakeWindow(dow: 1, startMin: 700, endMin: 600),
      ]) {
        expect(
          () => firmwareStorableWakeWindow(window),
          throwsA(
            isA<UnstorableWakeWindowException>().having(
              (e) => e.window,
              'window',
              window,
            ),
          ),
          reason: '$window',
        );
      }
    });

    test('an odd end past the largest end moves one minute earlier', () {
      expect(
        firmwareStorableWakeWindow(
          const FirmwareWakeWindow(dow: 6, startMin: 0, endMin: 1441),
        ),
        const FirmwareWakeWindow(dow: 6, startMin: 0, endMin: 1440),
      );
    });

    test('a window outside the firmware table is refused', () {
      for (final window in const [
        FirmwareWakeWindow(dow: 7, startMin: 0, endMin: 60),
        FirmwareWakeWindow(dow: -1, startMin: 0, endMin: 60),
        FirmwareWakeWindow(dow: 2, startMin: -1, endMin: 60),
        FirmwareWakeWindow(dow: 2, startMin: 0, endMin: 1442),
      ]) {
        expect(
          () => firmwareStorableWakeWindow(window),
          throwsA(isA<UnstorableWakeWindowException>()),
          reason: '$window',
        );
      }
    });

    test('a window over midnight keeps both of its parts', () {
      final parts = translateWakeSchedules(const [
        WakeSchedule(
          id: 'late-friday',
          hour: 23,
          minute: 0,
          daysOfWeek: {DateTime.friday},
          enabled: true,
          keepAwakeFor: 121,
        ),
      ]);
      expect(parts, const [
        FirmwareWakeWindow(dow: 5, startMin: 1380, endMin: 1440),
        FirmwareWakeWindow(dow: 6, startMin: 0, endMin: 61),
      ]);

      expect(parts.map(firmwareStorableWakeWindow).toList(), const [
        FirmwareWakeWindow(dow: 5, startMin: 1380, endMin: 1440),
        FirmwareWakeWindow(dow: 6, startMin: 0, endMin: 62),
      ]);
    });
  });

  group('pushFirmwareWakeSchedule sends only storable entries', () {
    test('the Codex example sends a non-empty Thursday window', () async {
      final transport = FakeBleTransport();
      final bengle = await _connectedBengle(transport);

      await bengle.pushFirmwareWakeSchedule(
        secondsSinceSundayLocal: 0,
        windows: const [FirmwareWakeWindow(dow: 4, startMin: 420, endMin: 421)],
      );

      final entries = _mmrWritesTo(transport, BengleMmr.scheduleEntry.address);
      expect(entries, [17637798]);
      final stored = _decode(_storedByFirmware(entries.single));
      expect(stored.startMin < stored.endMin, isTrue);
      expect(_mmrWritesTo(transport, BengleMmr.scheduleControl.address), [
        0,
        1,
      ]);
    });

    test('dow 0 to 3 send window.pack() unchanged', () async {
      final transport = FakeBleTransport();
      final bengle = await _connectedBengle(transport);
      const windows = [
        FirmwareWakeWindow(dow: 0, startMin: 1, endMin: 3),
        FirmwareWakeWindow(dow: 1, startMin: 420, endMin: 421),
        FirmwareWakeWindow(dow: 2, startMin: 0, endMin: 1439),
        FirmwareWakeWindow(dow: 3, startMin: 1438, endMin: 1439),
      ];

      await bengle.pushFirmwareWakeSchedule(
        secondsSinceSundayLocal: 0,
        windows: windows,
      );

      expect(_mmrWritesTo(transport, BengleMmr.scheduleEntry.address), [
        for (final w in windows) w.pack(),
      ]);
    });

    test('a refused window fails the push before the first MMR write, so the '
        'table in the machine stays as it was', () async {
      final transport = FakeBleTransport();
      final bengle = await _connectedBengle(transport);
      const refused = FirmwareWakeWindow(dow: 4, startMin: 1440, endMin: 1441);

      await expectLater(
        bengle.pushFirmwareWakeSchedule(
          secondsSinceSundayLocal: 123456,
          windows: const [
            FirmwareWakeWindow(dow: 1, startMin: 360, endMin: 390),
            refused,
          ],
        ),
        throwsA(
          isA<UnstorableWakeWindowException>().having(
            (e) => e.window,
            'window',
            refused,
          ),
        ),
      );

      expect(
        transport.writes.where(
          (w) => w.characteristicUUID == Endpoint.writeToMMR.uuid,
        ),
        isEmpty,
      );
    });
  });
}
