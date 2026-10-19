import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/skin_webview_composition.dart';

void main() {
  group('skin WebView settings', () {
    for (final platform in TargetPlatform.values) {
      for (final texture in [false, true]) {
        test('preserves skin scaling for $platform, texture: $texture', () {
          final settings = createSkinWebViewSettings(
            platform: platform,
            textureComposition: texture,
          );
          expect(settings.textZoom, 100);
          expect(settings.supportZoom, isFalse);
          expect(settings.builtInZoomControls, isFalse);
        });
      }
    }
  });
}
