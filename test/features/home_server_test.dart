import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/features/home/presentation/home_screen.dart";

import "../helpers/fake_server_host.dart";

/// Home's server card against a fake host: what the person sees for each state.
void main() {
  final Finder networkSwitch = find.widgetWithText(SwitchListTile, "Allow other devices on my network");
  final Finder httpsSwitch = find.widgetWithText(SwitchListTile, "HTTPS (encrypted)");
  final Finder httpSwitch = find.widgetWithText(SwitchListTile, "HTTP (not encrypted)");

  Widget harness(FakeServerHost host, {bool withAdmin = true}) {
    return ProviderScope(
      overrides: [
        serverHostProvider.overrideWithValue(host),
        accountRepositoryProvider.overrideWithValue(
          InMemoryAccountRepository(
            withAdmin
                ? <Account>[
                    Account(id: "1", username: "admin", passwordHash: "x", createdAt: DateTime.utc(2026)),
                  ]
                : <Account>[],
          ),
        ),
        storageRootRepositoryProvider.overrideWithValue(InMemoryStorageRootRepository()),
      ],
      child: MaterialApp(theme: AuroraTheme.light(), home: const HomeScreen()),
    );
  }

  testWidgets("start -> running shows the endpoint; stop returns to off", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost();
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    expect(find.text("Server off"), findsOneWidget);
    expect(find.text("Start server"), findsOneWidget);

    await tester.tap(find.text("Start server"));
    await tester.pumpAndSettle();

    expect(host.starts, 1);
    expect(find.text("Server on"), findsOneWidget);
    expect(find.text(FakeServerHost.endpoint), findsOneWidget);
    expect(find.text("Stop server"), findsOneWidget);

    await tester.tap(find.text("Stop server"));
    await tester.pumpAndSettle();

    expect(host.stops, 1);
    expect(find.text("Server off"), findsOneWidget);
    expect(find.text("Start server"), findsOneWidget);
  });

  testWidgets("while starting the button is disabled", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost()..holdInStarting = true;
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Start server"));
    await tester.pumpAndSettle();

    // Chip and button both read "Starting…".
    expect(find.text("Starting…"), findsNWidgets(2));
    await tester.tap(find.text("Starting…").last);
    await tester.pumpAndSettle();
    expect(host.starts, 1, reason: "a second tap while starting must not start again");
  });

  testWidgets("a failed start shows Try again and hides details behind a disclosure", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost(
      const ServerState(run: ServerRunState.failed, detail: "Couldn't open the local listener: port busy"),
    );
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    expect(find.text("Failed"), findsOneWidget);
    expect(find.text("Try again"), findsOneWidget);
    expect(find.text("Technical details"), findsOneWidget);
  });

  testWidgets("if asking the service to start throws, the person sees a message", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost()..failStart = const UnexpectedFailure(debugDetail: "x");
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Start server"));
    await tester.pumpAndSettle();

    expect(find.text("Something went wrong. Please try again."), findsOneWidget);
    expect(find.text("Server off"), findsOneWidget);
  });

  testWidgets("shows the certificate fingerprint", (WidgetTester tester) async {
    _tall(tester);
    await tester.pumpWidget(harness(FakeServerHost()));
    await tester.pumpAndSettle();

    expect(find.text("Certificate fingerprint (SHA-256)"), findsOneWidget);
    expect(find.text(FakeServerHost.fingerprint), findsOneWidget);
  });

  testWidgets("network access is OFF by default and asks before turning on", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost();
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.descendant(of: networkSwitch, matching: find.byType(Switch))).value, isFalse);

    await tester.tap(find.descendant(of: networkSwitch, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(find.text("Allow network access?"), findsOneWidget);
    expect(host.savedConfig.allowNetworkAccess, isFalse, reason: "nothing saved until confirmed");

    await tester.tap(find.text("Cancel"));
    await tester.pumpAndSettle();
    expect(host.savedConfig.allowNetworkAccess, isFalse);

    await tester.tap(find.descendant(of: networkSwitch, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Allow"));
    await tester.pumpAndSettle();
    expect(host.savedConfig.allowNetworkAccess, isTrue);
    expect(tester.widget<Switch>(find.descendant(of: networkSwitch, matching: find.byType(Switch))).value, isTrue);
  });

  testWidgets("turning network access off needs no confirmation", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost()..savedConfig = const ServerConfig(allowNetworkAccess: true);
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: networkSwitch, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(find.text("Allow network access?"), findsNothing);
    expect(host.savedConfig.allowNetworkAccess, isFalse);
  });

  testWidgets("the switch is locked while the server runs", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost();
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Start server"));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.descendant(of: networkSwitch, matching: find.byType(Switch))).onChanged, isNull);
    // Both the network switch and the HTTP switch explain why they are locked.
    expect(find.text("Stop the server to change this."), findsNWidgets(2));
  });

  testWidgets("copy is honest about exposure: local-only vs reachable on the network", (WidgetTester tester) async {
    final FakeServerHost local = FakeServerHost(
      const ServerState(run: ServerRunState.running, endpoint: "https://127.0.0.1:8443/"),
    );
    _tall(tester);
    await tester.pumpWidget(harness(local));
    await tester.pumpAndSettle();
    expect(find.textContaining("answers on this phone only"), findsOneWidget);
    expect(find.textContaining("reachable from devices on your local network"), findsNothing);

    final FakeServerHost lan = FakeServerHost(
      const ServerState(run: ServerRunState.running, endpoint: "https://192.168.1.5:8443/"),
    );
    _tall(tester);
    await tester.pumpWidget(harness(lan));
    await tester.pumpAndSettle();
    expect(find.textContaining("reachable from devices on your local network"), findsOneWidget);
    expect(find.textContaining("nothing is exposed to your network"), findsNothing);
  });


  testWidgets("HTTPS is on and HTTP is off by default", (WidgetTester tester) async {
    _tall(tester);
    await tester.pumpWidget(harness(FakeServerHost()));
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(httpsSwitch).value, isTrue);
    expect(tester.widget<SwitchListTile>(httpSwitch).value, isFalse);
  });

  testWidgets("turning HTTP on warns first and saves only after confirming", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost();
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    await tester.tap(httpSwitch);
    await tester.pumpAndSettle();
    expect(find.text("Turn on unencrypted HTTP?"), findsOneWidget);
    expect(host.savedConfig.httpEnabled, isFalse, reason: "nothing saved until confirmed");

    await tester.tap(find.text("Cancel"));
    await tester.pumpAndSettle();
    expect(host.savedConfig.httpEnabled, isFalse);

    await tester.tap(httpSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text("Turn on HTTP"));
    await tester.pumpAndSettle();
    expect(host.savedConfig.httpEnabled, isTrue);
    expect(host.savedConfig.httpsEnabled, isTrue, reason: "HTTPS stays on alongside HTTP");
    expect(tester.widget<SwitchListTile>(httpSwitch).value, isTrue);
  });

  testWidgets("turning HTTP off needs no confirmation", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost()
      ..savedConfig = const ServerConfig(httpEnabled: true);
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    await tester.tap(httpSwitch);
    await tester.pumpAndSettle();

    expect(find.text("Turn on unencrypted HTTP?"), findsNothing);
    expect(host.savedConfig.httpEnabled, isFalse);
  });

  testWidgets("at least one protocol must stay on", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost();
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    await tester.tap(httpsSwitch); // HTTPS is the only one on; HTTP is off
    await tester.pumpAndSettle();

    expect(find.text("Keep at least one of HTTPS and HTTP on."), findsOneWidget);
    expect(host.savedConfig.httpsEnabled, isTrue);
  });

  testWidgets("HTTP only is allowed once HTTPS is switched off after HTTP is on", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost()
      ..savedConfig = const ServerConfig(httpEnabled: true);
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    await tester.tap(httpsSwitch);
    await tester.pumpAndSettle();

    expect(host.savedConfig.httpsEnabled, isFalse);
    expect(host.savedConfig.httpEnabled, isTrue);
  });

  testWidgets("the protocol switches lock while the server runs", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost();
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Start server"));
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(httpsSwitch).onChanged, isNull);
    expect(tester.widget<SwitchListTile>(httpSwitch).onChanged, isNull);
  });

  testWidgets("every endpoint is listed and a LAN HTTP one is flagged as not encrypted", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost(
      const ServerState(
        run: ServerRunState.running,
        endpoint: "https://192.168.1.5:8443/",
        endpoints: <String>["https://192.168.1.5:8443/", "http://192.168.1.5:8080/"],
      ),
    );
    _tall(tester);
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    expect(find.text("https://192.168.1.5:8443/"), findsOneWidget);
    expect(find.text("http://192.168.1.5:8080/"), findsOneWidget);
    expect(find.text("Not encrypted — use only on a network you trust."), findsOneWidget);
    expect(find.textContaining("HTTPS (encrypted) and HTTP (not encrypted)"), findsOneWidget);
  });

  testWidgets("no admin yet: an admin card is shown and network access can't be turned on", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost();
    _tall(tester);
    await tester.pumpWidget(harness(host, withAdmin: false));
    await tester.pumpAndSettle();

    expect(find.text("No admin account yet"), findsOneWidget);
    expect(find.text("Create admin account"), findsOneWidget);

    await tester.tap(find.descendant(of: networkSwitch, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(find.text("Create an admin account first"), findsOneWidget);
    expect(find.text("Allow network access?"), findsNothing, reason: "must not even offer exposure yet");
    await tester.tap(find.text("Not now"));
    await tester.pumpAndSettle();
    expect(host.savedConfig.allowNetworkAccess, isFalse);
  });

  testWidgets("with an admin the prompt card is hidden", (WidgetTester tester) async {
    _tall(tester);
    await tester.pumpWidget(harness(FakeServerHost()));
    await tester.pumpAndSettle();
    expect(find.text("No admin account yet"), findsNothing);
  });
}

/// The card is taller than the default test surface; give it room so every
/// switch is built and hit-testable.
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}
