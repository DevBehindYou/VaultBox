import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/core/design/aurora_widgets.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/features/settings/presentation/protocols_screen.dart";

import "../helpers/fake_server_host.dart";

/// Protocols & Network: the switches that used to sit on Home, now with ports,
/// the WebDAV address and a guide. Behaviour is unchanged where it was tested
/// before: asking before exposing anything, locking while the server runs.
void main() {
  String? copied;

  setUp(() => copied = null);

  Widget harness(FakeServerHost host, {bool withAdmin = true}) {
    final GoRouter router = GoRouter(
      routes: <RouteBase>[
        GoRoute(path: "/", builder: (BuildContext c, GoRouterState s) => const ProtocolsScreen()),
        GoRoute(path: "/admin/new", builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text("route:/admin/new"))),
        GoRoute(path: "/settings/security", builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text("route:/settings/security"))),
      ],
    );
    return ProviderScope(
      overrides: [
        serverHostProvider.overrideWithValue(host),
        accountRepositoryProvider.overrideWithValue(
          InMemoryAccountRepository(
            withAdmin
                ? <Account>[Account(id: "1", username: "admin", passwordHash: "x", createdAt: DateTime.utc(2026))]
                : <Account>[],
          ),
        ),
      ],
      child: MaterialApp.router(theme: AuroraTheme.light(), routerConfig: router),
    );
  }

  Future<void> show(WidgetTester tester, FakeServerHost host, {bool withAdmin = true}) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(host, withAdmin: withAdmin));
    await tester.pumpAndSettle();
  }

  /// The switch in the card (or row group) that holds [title].
  Finder switchIn(String title) =>
      find.descendant(of: find.ancestor(of: find.text(title), matching: find.byType(AuroraCard)), matching: find.byType(Switch));

  bool isOn(WidgetTester tester, String title) => tester.widget<Switch>(switchIn(title)).value;

  void captureClipboard() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == "Clipboard.setData") copied = (call.arguments as Map<Object?, Object?>)["text"] as String?;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  group("the server service", () {
    testWidgets("its switch starts and stops the server, and the row says what state it is in", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host);
      expect(find.text("Off"), findsNWidgets(2), reason: "the service, and plain HTTP which is off too");

      await tester.tap(switchIn("Server service"));
      await tester.pumpAndSettle();
      expect(host.starts, 1);
      expect(find.text("Running · this phone only"), findsOneWidget);

      await tester.tap(switchIn("Server service"));
      await tester.pumpAndSettle();
      expect(host.stops, 1);
      expect(find.text("Off"), findsNWidgets(2));
    });

    testWidgets("on the network it shows where", (WidgetTester tester) async {
      await show(
        tester,
        FakeServerHost(
          const ServerState(run: ServerRunState.running, endpoint: "https://192.168.1.5:8443/"),
        ),
      );

      expect(find.text("Running · 192.168.1.5:8443"), findsOneWidget);
    });
  });

  group("defaults", () {
    testWidgets("HTTPS is on, plain HTTP is off, network access is off", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      expect(isOn(tester, "Web Portal"), isTrue);
      expect(isOn(tester, "Plain HTTP"), isFalse);
      expect(isOn(tester, "Allow other devices on my network"), isFalse);
      expect(find.text("Ready"), findsOneWidget, reason: "HTTPS is set up but the server isn't running");
      expect(find.text("Never on the internet"), findsOneWidget);
    });

    testWidgets("the ports are shown", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      expect(find.text("8443"), findsOneWidget);
      expect(find.text("8080"), findsOneWidget);
    });
  });

  group("plain HTTP", () {
    testWidgets("turning it on warns first and saves only after confirming", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host);

      await tester.tap(switchIn("Plain HTTP"));
      await tester.pumpAndSettle();
      expect(find.text("Turn on unencrypted HTTP?"), findsOneWidget);
      expect(host.savedConfig.httpEnabled, isFalse, reason: "nothing saved until confirmed");

      await tester.tap(find.text("Cancel"));
      await tester.pumpAndSettle();
      expect(host.savedConfig.httpEnabled, isFalse);

      await tester.tap(switchIn("Plain HTTP"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Turn on HTTP"));
      await tester.pumpAndSettle();
      expect(host.savedConfig.httpEnabled, isTrue);
      expect(host.savedConfig.httpsEnabled, isTrue, reason: "HTTPS stays on alongside HTTP");
      expect(isOn(tester, "Plain HTTP"), isTrue);
      expect(find.text("Insecure · unencrypted"), findsOneWidget);
    });

    testWidgets("turning it off needs no confirmation", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost()..savedConfig = const ServerConfig(httpEnabled: true);
      await show(tester, host);

      await tester.tap(switchIn("Plain HTTP"));
      await tester.pumpAndSettle();

      expect(find.text("Turn on unencrypted HTTP?"), findsNothing);
      expect(host.savedConfig.httpEnabled, isFalse);
    });

    testWidgets("at least one protocol must stay on", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host);

      await tester.tap(switchIn("Web Portal")); // HTTPS is the only one on
      await tester.pumpAndSettle();

      expect(find.text("Keep at least one of HTTPS and HTTP on."), findsOneWidget);
      expect(host.savedConfig.httpsEnabled, isTrue);
    });

    testWidgets("HTTPS can go off once HTTP is on", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost()..savedConfig = const ServerConfig(httpEnabled: true);
      await show(tester, host);

      await tester.tap(switchIn("Web Portal"));
      await tester.pumpAndSettle();

      expect(host.savedConfig.httpsEnabled, isFalse);
      expect(host.savedConfig.httpEnabled, isTrue);
    });
  });

  group("network access", () {
    testWidgets("asks before turning on, and saves nothing until confirmed", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host);

      await tester.tap(switchIn("Allow other devices on my network"));
      await tester.pumpAndSettle();
      expect(find.text("Allow network access?"), findsOneWidget);
      expect(host.savedConfig.allowNetworkAccess, isFalse);

      await tester.tap(find.text("Cancel"));
      await tester.pumpAndSettle();
      expect(host.savedConfig.allowNetworkAccess, isFalse);

      await tester.tap(switchIn("Allow other devices on my network"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Allow"));
      await tester.pumpAndSettle();
      expect(host.savedConfig.allowNetworkAccess, isTrue);
      expect(isOn(tester, "Allow other devices on my network"), isTrue);
    });

    testWidgets("turning it off needs no confirmation", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost()..savedConfig = const ServerConfig(allowNetworkAccess: true);
      await show(tester, host);

      await tester.tap(switchIn("Allow other devices on my network"));
      await tester.pumpAndSettle();

      expect(find.text("Allow network access?"), findsNothing);
      expect(host.savedConfig.allowNetworkAccess, isFalse);
    });

    testWidgets("without an admin account it can't be turned on, and offers to create one", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host, withAdmin: false);

      await tester.tap(switchIn("Allow other devices on my network"));
      await tester.pumpAndSettle();

      expect(find.text("Create an admin account first"), findsOneWidget);
      expect(find.text("Allow network access?"), findsNothing, reason: "must not even offer exposure yet");

      await tester.tap(find.text("Create account"));
      await tester.pumpAndSettle();
      expect(find.text("route:/admin/new"), findsOneWidget);
      expect(host.savedConfig.allowNetworkAccess, isFalse);
    });
  });

  group("while the server runs", () {
    const ServerState running = ServerState(run: ServerRunState.running, endpoint: "https://127.0.0.1:8443/");

    testWidgets("every setting is locked, and says why", (WidgetTester tester) async {
      await show(tester, FakeServerHost(running));

      expect(tester.widget<Switch>(switchIn("Web Portal")).onChanged, isNull);
      expect(tester.widget<Switch>(switchIn("Plain HTTP")).onChanged, isNull);
      expect(tester.widget<Switch>(switchIn("Allow other devices on my network")).onChanged, isNull);
      expect(find.text("Stop the server to change this."), findsNWidgets(3));
      expect(find.text("Change"), findsNothing, reason: "ports can't be edited while it listens");
      expect(find.text("Listening"), findsOneWidget);
    });
  });

  group("ports", () {
    testWidgets("a new port is saved", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host);

      await tester.tap(find.text("Change").first);
      await tester.pumpAndSettle();
      expect(find.text("HTTPS port"), findsOneWidget);
      await tester.enterText(find.byType(TextField), "9443");
      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();

      expect(host.savedConfig.port, 9443);
      expect(find.text("9443"), findsOneWidget);
    });

    testWidgets("a port below 1024 or not a number is refused, and nothing is saved", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host);

      await tester.tap(find.text("Change").first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), "80");
      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();
      expect(find.text("Use a number from 1024 to 65535."), findsOneWidget);

      await tester.enterText(find.byType(TextField), "abc");
      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();
      expect(find.text("Use a number from 1024 to 65535."), findsOneWidget);
      expect(host.savedConfig.port, 8443);
    });

    testWidgets("the two connections can't share a port", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host);

      await tester.tap(find.text("Change").first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), "8080"); // the HTTP port
      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();

      expect(find.text("That port is used by the other connection."), findsOneWidget);
      expect(host.savedConfig.port, 8443);
    });

    testWidgets("Cancel changes nothing", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host);

      await tester.tap(find.text("Change").last);
      await tester.pumpAndSettle();
      expect(find.text("HTTP port"), findsOneWidget);
      await tester.tap(find.text("Cancel"));
      await tester.pumpAndSettle();

      expect(host.savedConfig.httpPort, 8080);
    });
  });

  group("WebDAV", () {
    testWidgets("with the server off it shows the shape of the address, and can't copy it yet", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      expect(find.text("https://<phone address>:8443/dav/"), findsOneWidget);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.copy)).onPressed, isNull);
    });

    testWidgets("with the server on it shows the real address and copies it", (WidgetTester tester) async {
      captureClipboard();
      await show(
        tester,
        FakeServerHost(const ServerState(run: ServerRunState.running, endpoint: "https://192.168.1.5:8443/")),
      );

      expect(find.text("https://192.168.1.5:8443/dav/"), findsOneWidget);
      await tester.tap(find.byTooltip("Copy WebDAV address"));
      await tester.pumpAndSettle();

      expect(copied, "https://192.168.1.5:8443/dav/");
      expect(find.text("WebDAV address copied"), findsOneWidget);
    });

    testWidgets("the setup guide covers phones and computers, with this phone's address in it", (WidgetTester tester) async {
      await show(
        tester,
        FakeServerHost(const ServerState(run: ServerRunState.running, endpoint: "https://192.168.1.5:8443/")),
      );

      await tester.tap(find.text("Setup guide for phones and computers"));
      await tester.pumpAndSettle();

      expect(find.text("Connect with WebDAV"), findsOneWidget);
      expect(find.textContaining("Another phone"), findsOneWidget);
      expect(find.textContaining("Mac (Finder)"), findsOneWidget);
      expect(find.textContaining("Host: 192.168.1.5   Port: 8443   Path: /dav"), findsOneWidget);
    });
  });

  testWidgets("the Web Portal card links to the certificate", (WidgetTester tester) async {
    await show(tester, FakeServerHost());

    await tester.tap(find.text("Certificate and security"));
    await tester.pumpAndSettle();

    expect(find.text("route:/settings/security"), findsOneWidget);
  });
}
