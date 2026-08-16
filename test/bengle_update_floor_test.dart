import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/android_updater.dart';

/// The Bengle port builds off `port/rea-*`, whose `git describe` picks up
/// whatever upstream tag it happens to sit on. That makes a port build
/// advertise an *upstream* version (0.7.12), so the in-app updater treats every
/// later tadelv/reaprime release as an upgrade and offers to replace the port
/// build with stock upstream — silently discarding the whole Bengle stack.
///
/// The fix is a version floor: tag the port branch `v1.0.0-bengle.N` so
/// `_isNewerVersion` compares [1,0,0] against upstream's 0.x and declines.
/// These tests pin both halves — the exposure, and that the floor closes it.
void main() {
  /// Mirrors the shape of api.github.com/repos/tadelv/reaprime/releases,
  /// newest first, with the real tags upstream had on 2026-08-16. Upstream has
  /// since crossed a MINOR boundary (v0.8.0-beta.1), so the fixture carries it:
  /// a floor that only ever met 0.7.x would not prove the comparison still
  /// holds as upstream climbs toward 1.0.
  String releasesJson() => jsonEncode([
    {
      'tag_name': 'v0.8.0-beta.1',
      'prerelease': true,
      'body': 'beta',
      'assets': [
        {
          'name': 'decent-android-0.8.0-beta.1.apk',
          'browser_download_url': 'https://example.com/beta.apk',
        },
      ],
    },
    {
      'tag_name': 'v0.7.17',
      'prerelease': false,
      'body': 'stable',
      'assets': [
        {
          'name': 'decent-android-0.7.17.apk',
          'browser_download_url': 'https://example.com/stable.apk',
        },
      ],
    },
  ]);

  AndroidUpdater updaterReturningReleases() => AndroidUpdater(
    owner: 'tadelv',
    repo: 'reaprime',
    httpClient: MockClient(
      (request) async => http.Response(releasesJson(), 200),
    ),
  );

  group('port build without a version floor (the exposure)', () {
    test(
      '0.7.12 is offered stock upstream 0.7.17 on the stable channel',
      () async {
        final update = await updaterReturningReleases().checkForUpdate(
          '0.7.12',
          channel: UpdateChannel.stable,
        );

        // This is what would wipe the Bengle stack if the user tapped install.
        expect(update, isNotNull);
        expect(update!.version, '0.7.17');
      },
    );

    test('a bare dev build accepts anything', () async {
      final update = await updaterReturningReleases().checkForUpdate(
        '0.0.0-dev',
        channel: UpdateChannel.stable,
      );

      expect(update, isNotNull);
    });
  });

  group('port build with the v1.0.0-bengle floor', () {
    for (final channel in UpdateChannel.values) {
      test('no upstream release is offered on the $channel channel', () async {
        final update = await updaterReturningReleases().checkForUpdate(
          '1.0.0-bengle.2',
          channel: channel,
        );

        expect(
          update,
          isNull,
          reason: 'no upstream 0.x release may outrank the 1.0.0 port floor',
        );
      });
    }

    test('the floor still yields a valid Android versionName', () {
      // flutter_with_commit.sh derives BUILD_NAME as "${VERSION%%-*}".
      const version = '1.0.0-bengle.2';
      expect(version.split('-').first, '1.0.0');
    });
  });
}
