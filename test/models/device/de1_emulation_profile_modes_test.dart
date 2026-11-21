import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_emulation_reporter.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';

import '../../helpers/fake_ble_transport.dart';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('assets/defaultProfiles/$name').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _basketWith(void Function(Map<String, dynamic>) edit) {
  final json = _json('7g_basket.json');
  final steps = (json['steps'] as List).cast<Map<String, dynamic>>();
  edit(steps.last);
  return json;
}

final _cases = <String, Map<String, dynamic> Function()>{
  'pressure and flow only': () => _json('7g_basket.json'),
  'Lever (lever_classic_demo)': () => _json('lever_classic_demo.json'),
  'Power': () => _basketWith((s) {
    s['pump'] = 'power';
    s['power'] = 1500;
  }),
  'HOLD transition': () => _basketWith((s) => s['transition'] = 'hold'),
};

void main() {
  for (final MapEntry(key: label, value: build) in _cases.entries) {
    final expected = label == 'pressure and flow only' ? 1 : 0;
    test('$label with the flag on writes data[3] = $expected', () async {
      final profile = Profile.fromJson(build()..['de1_emulation'] = true);
      expect(profile.de1Emulation, isTrue);
      expect(profile.toJson()['de1_emulation'], isTrue);

      final transport = FakeBleTransport();
      addTearDown(transport.dispose);
      transport.queuePaletteHydrationResponses();
      transport.queueOnConnectResponses(v13Model: 128, profileModeCaps: 0x7);
      final bengle = Bengle(transport: transport);
      await bengle.onConnect();
      transport.writes.clear();

      await bengle.setProfile(profile);

      final tails = transport.writes
          .where(
            (w) =>
                w.characteristicUUID == Endpoint.frameWrite.uuid &&
                w.data.length == 8 &&
                w.data[0] == profile.steps.length,
          )
          .toList();
      expect(tails, hasLength(1));
      expect(tails.single.data[3], expected);
      expect(de1EmulationSentBy(bengle), expected == 1);
      expect(profile.usesDe1Emulation(machineSupported: true), expected == 1);
    });
  }
}
