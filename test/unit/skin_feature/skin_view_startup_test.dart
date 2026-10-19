import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/services/webview_compatibility_checker.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../helpers/mock_de1_controller.dart';
import '../../helpers/mock_settings_service.dart';

class _WebViewPlatform extends InAppWebViewPlatform {
  final Future<String?> version;

  _WebViewPlatform(this.version);

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _WebView(params);

  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      _Environment(version);
}

class _Environment extends PlatformWebViewEnvironment {
  final Future<String?> version;

  _Environment(this.version)
    : super.implementation(const PlatformWebViewEnvironmentCreationParams());

  @override
  Future<String?> getAvailableVersion({String? browserExecutableFolder}) =>
      version;
}

class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;

  @override
  void dispose() {}
}

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 1),
      );
}

class _UrlLauncher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final void Function(Uri, PreferredLaunchMode) record;

  _UrlLauncher(this.record);

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    record(Uri.parse(url), options.mode);
    return true;
  }

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;
}

Future<void> _pumpSkin(WidgetTester tester, {Future<String?>? version}) async {
  final previous = InAppWebViewPlatform.instance;
  InAppWebViewPlatform.instance = _WebViewPlatform(
    version ?? Future.value('test'),
  );
  WebViewCompatibilityChecker.clearCache();
  final settings = SettingsController(MockSettingsService());
  final logs = WebViewLogService(logDirectoryPath: '.');
  final display = DisplayController(
    de1Controller: MockDe1Controller(controller: DeviceController(const [])),
    settingsController: settings,
    setBrightness: (_) async {},
    resetBrightness: () async {},
    enableWakeLock: () async {},
    disableWakeLock: () async {},
    platformSupport: const DisplayPlatformSupport(
      brightness: false,
      wakeLock: false,
    ),
  );
  addTearDown(() {
    display.dispose();
    settings.dispose();
    logs.dispose();
    WebViewCompatibilityChecker.clearCache();
    if (previous != null) InAppWebViewPlatform.instance = previous;
  });
  await tester.pumpWidget(
    MaterialApp(
      routes: {
        LauncherView.routeName: (_) => const Scaffold(body: Text('Dashboard')),
      },
      home: SkinView(
        settingsController: settings,
        webViewLogService: logs,
        deviceIp: '127.0.0.1',
        displayController: display,
        port: 24800,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

PlatformInAppWebViewWidgetCreationParams _params(WidgetTester tester) =>
    tester.widget<InAppWebView>(find.byType(InAppWebView)).platform.params;

void main() {
  final controller = InAppWebViewController.fromPlatform(
    platform: _Controller(),
  );
  final url = WebUri('http://localhost:24800/');
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  for (final action in ['Open in Browser', 'Go to Dashboard']) {
    testWidgets('Windows timeout recovery: $action', (tester) async {
      final previous = UrlLauncherPlatform.instance;
      Uri? launched;
      PreferredLaunchMode? mode;
      UrlLauncherPlatform.instance = _UrlLauncher((uri, launchMode) {
        launched = uri;
        mode = launchMode;
      });
      addTearDown(() => UrlLauncherPlatform.instance = previous);
      await _pumpSkin(tester);
      await tester.pump(const Duration(seconds: 30));
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();

      expect(find.text('Dashboard'), findsOneWidget);
      if (action == 'Open in Browser') {
        expect(launched?.origin, 'http://localhost:3000');
        expect(mode, PreferredLaunchMode.externalApplication);
      } else {
        expect(launched, isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: windows);
  }

  testWidgets(
    'Windows creation timeout retains the view and offers recovery',
    (tester) async {
      await _pumpSkin(tester);
      await tester.pump(const Duration(seconds: 29));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('WebView Error'), findsOneWidget);
      expect(
        find.textContaining('embedded browser did not start'),
        findsOneWidget,
      );
      expect(find.text('Open in Browser'), findsOneWidget);
      expect(find.text('Go to Dashboard'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(InAppWebView), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: windows,
  );

  testWidgets(
    'Windows timeout distinguishes a created view from a loaded page',
    (tester) async {
      await _pumpSkin(tester);
      _params(tester).onWebViewCreated!(controller);
      _params(tester).onLoadStart!(controller, url);
      await tester.pump(const Duration(seconds: 30));

      expect(
        find.textContaining('skin did not finish loading'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: windows,
  );

  testWidgets('successful Windows load cancels the timeout', (tester) async {
    await _pumpSkin(tester);
    _params(tester).onLoadStop!(controller, url);
    await tester.pump(const Duration(seconds: 31));

    expect(find.text('WebView Error'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: windows);

  testWidgets('a late Windows load recovers without recreating the view', (
    tester,
  ) async {
    await _pumpSkin(tester);
    final params = _params(tester);
    final view = tester.element(find.byType(InAppWebView));
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('WebView Error'), findsOneWidget);
    expect(tester.element(find.byType(InAppWebView)), same(view));

    params.onWebViewCreated!(controller);
    params.onLoadStart!(controller, url);
    await tester.pump();
    expect(find.text('WebView Error'), findsOneWidget);
    params.onLoadStop!(controller, url);
    await tester.pump();
    expect(find.text('WebView Error'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(InAppWebView), findsOneWidget);
    expect(tester.element(find.byType(InAppWebView)), same(view));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: windows);

  testWidgets(
    'a main-frame error is not overwritten by the Windows timeout',
    (tester) async {
      await _pumpSkin(tester);
      _params(tester).onReceivedError!(
        controller,
        WebResourceRequest(url: url, isForMainFrame: true),
        WebResourceError(
          type: WebResourceErrorType.UNKNOWN,
          description: 'connection refused',
        ),
      );
      await tester.pump(const Duration(seconds: 31));

      expect(
        find.text('Failed to load skin: connection refused'),
        findsOneWidget,
      );
      expect(find.textContaining('30 seconds'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: windows,
  );

  testWidgets('disposing the Windows view cancels its startup timeout', (
    tester,
  ) async {
    await _pumpSkin(tester);
    final params = _params(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    params.onWebViewCreated!(controller);
    params.onLoadStart!(controller, url);
    params.onLoadStop!(controller, url);
    await tester.pump(const Duration(seconds: 31));
    expect(tester.takeException(), isNull);
  }, variant: windows);

  testWidgets(
    'a compatibility probe can finish after the Windows view closes',
    (tester) async {
      final version = Completer<String?>();
      await _pumpSkin(tester, version: version.future);
      await tester.pumpWidget(const SizedBox.shrink());
      version.complete('test');
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    variant: windows,
  );

  testWidgets('Windows startup errors fit a small window', (tester) async {
    tester.view.physicalSize = const Size(360, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpSkin(tester);
    await tester.pump(const Duration(seconds: 30));

    expect(find.text('WebView Error'), findsOneWidget);
    expect(
      tester.getRect(find.text('Go to Dashboard')).bottom,
      lessThanOrEqualTo(320),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: windows);

  testWidgets(
    'other platforms do not acquire a Windows startup timeout',
    (tester) async {
      await _pumpSkin(tester);
      await tester.pump(const Duration(seconds: 31));

      expect(find.text('WebView Error'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
