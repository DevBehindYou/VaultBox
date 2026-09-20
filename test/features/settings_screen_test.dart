import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_activity_repository.dart";
import "package:vaultbox/data/repositories/in_memory_share_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/activity.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/features/settings/presentation/diagnostics_screen.dart";
import "package:vaultbox/features/settings/presentation/settings_screen.dart";

import "../helpers/fake_clock.dart";
import "../helpers/fake_server_host.dart";

void main() {
  late FakeServerHost host;
  late InMemoryAccountRepository accounts;
  late InMemoryActivityRepository activity;
  late List<StorageRoot> roots;
  String? copied;

  setUp(() {
    host = FakeServerHost();
    accounts = InMemoryAccountRepository(<Account>[
      Account(id: "a1", username: "admin", passwordHash: "x", createdAt: DateTime.utc(2026)),
    ]);
    activity = InMemoryActivityRepository();
    roots = <StorageRoot>[
      const StorageRoot(
        id: "mem",
        displayName: "Phone storage",
        backendType: StorageBackendType.memory,
        uriOrPath: "memory://mem",
        capabilities: StorageCapabilities.fullLocal(),
        isDefault: true,
      ),
    ];
    copied = null;
  });

  Widget scoped(Widget child) {
    final BackendRegistry registry = BackendRegistry()..register(MemoryStorageBackend(id: "mem"));
    return ProviderScope(
      overrides: [
        serverHostProvider.overrideWithValue(host),
        accountRepositoryProvider.overrideWithValue(accounts),
        activityRepositoryProvider.overrideWithValue(activity),
        shareRepositoryProvider.overrideWithValue(InMemoryShareRepository()),
        storageRootRepositoryProvider.overrideWithValue(InMemoryStorageRootRepository(initial: roots)),
        backendRegistryProvider.overrideWithValue(registry),
        clockProvider.overrideWithValue(FakeClock(DateTime.utc(2026, 9, 20, 12))),
      ],
      child: child,
    );
  }

  Widget diagnostics() => scoped(MaterialApp(theme: AuroraTheme.light(), home: const DiagnosticsScreen()));

  void captureClipboard() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == "Clipboard.setData") copied = (call.arguments as Map<Object?, Object?>)["text"] as String?;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  group("Settings", () {
    Widget settings() {
      GoRoute stub(String path) => GoRoute(
        path: path,
        builder: (BuildContext c, GoRouterState s) => Scaffold(body: Text("route:/settings/$path")),
      );
      final GoRouter router = GoRouter(
        initialLocation: "/settings",
        routes: <RouteBase>[
          GoRoute(
            path: "/settings",
            builder: (BuildContext c, GoRouterState s) => const SettingsScreen(),
            routes: <RouteBase>[
              stub("protocols"),
              stub("security"),
              stub("storage"),
              stub("appearance"),
              GoRoute(path: "diagnostics", builder: (BuildContext c, GoRouterState s) => const DiagnosticsScreen()),
            ],
          ),
          GoRoute(path: "/share", builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text("route:/share"))),
        ],
      );
      return scoped(MaterialApp.router(theme: AuroraTheme.light(), routerConfig: router));
    }

    testWidgets("lists every group and says what is inside", (WidgetTester tester) async {
      _tall(tester);
      await tester.pumpWidget(settings());
      await tester.pumpAndSettle();

      for (final String title in <String>[
        "Server",
        "Protocols & Network",
        "Security & Sessions",
        "Storage",
        "Storage & Volumes",
        "Sharing",
        "People & links",
        "App",
        "Appearance & Display",
        "System",
        "Diagnostics",
        "About VaultBox",
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text("HTTPS 8443 · WebDAV"), findsOneWidget, reason: "read from the real settings");
      expect(find.text("1 location served"), findsOneWidget, reason: "and from the real storage list");
      expect(find.textContaining("Version 0.1.0"), findsOneWidget);
    });

    testWidgets("the protocols row follows what is switched on", (WidgetTester tester) async {
      host.savedConfig = const ServerConfig(httpEnabled: true, port: 9443);
      _tall(tester);
      await tester.pumpWidget(settings());
      await tester.pumpAndSettle();

      expect(find.text("HTTPS 9443 · HTTP 8080 · WebDAV"), findsOneWidget);
    });

    testWidgets("with no storage the row says so", (WidgetTester tester) async {
      roots = <StorageRoot>[];
      _tall(tester);
      await tester.pumpWidget(settings());
      await tester.pumpAndSettle();

      expect(find.text("Nothing added yet"), findsOneWidget);
    });

    testWidgets("each row opens its screen", (WidgetTester tester) async {
      _tall(tester);
      await tester.pumpWidget(settings());
      await tester.pumpAndSettle();

      for (final (String row, String route) in <(String, String)>[
        ("Protocols & Network", "route:/settings/protocols"),
        ("Security & Sessions", "route:/settings/security"),
        ("Storage & Volumes", "route:/settings/storage"),
        ("Appearance & Display", "route:/settings/appearance"),
        ("People & links", "route:/share"),
      ]) {
        await tester.tap(find.text(row));
        await tester.pumpAndSettle();
        expect(find.text(route), findsOneWidget, reason: row);

        final GoRouter router = GoRouter.of(tester.element(find.text(route)));
        router.go("/settings");
        await tester.pumpAndSettle();
      }
    });

    testWidgets("Diagnostics opens and runs the checks", (WidgetTester tester) async {
      _tall(tester);
      await tester.pumpWidget(settings());
      await tester.pumpAndSettle();

      await tester.tap(find.text("Diagnostics"));
      await tester.pumpAndSettle();

      expect(find.text("Everything looks fine."), findsOneWidget);
      expect(find.text("Run the checks again"), findsOneWidget);
    });
  });

  group("Diagnostics", () {
    testWidgets("a healthy phone: every check OK and a reassuring banner", (WidgetTester tester) async {
      _tall(tester);
      await tester.pumpWidget(diagnostics());
      await tester.pumpAndSettle();

      expect(find.text("Everything looks fine."), findsOneWidget);
      expect(find.text("Storage location · Phone storage"), findsOneWidget);
      expect(find.text("Readable and writable."), findsOneWidget);
      expect(find.text("Accounts"), findsOneWidget);
      expect(find.text("Encryption certificate"), findsOneWidget);
      expect(find.text("OK"), findsNWidgets(6));
      expect(find.text("Problem"), findsNothing);
    });

    testWidgets("trouble is counted, described, and comes with what to do", (WidgetTester tester) async {
      _tall(tester);
      accounts = InMemoryAccountRepository();
      roots = <StorageRoot>[];
      await tester.pumpWidget(diagnostics());
      await tester.pumpAndSettle();

      expect(find.text("2 things need a look."), findsOneWidget);
      expect(find.text("There is no admin account, so nobody can sign in."), findsOneWidget);
      expect(find.text("Create one on the Home tab."), findsOneWidget);
      expect(find.text("No storage location is set up, so there is nothing to share."), findsOneWidget);
      expect(find.text("Problem"), findsOneWidget);
      expect(find.text("Look"), findsOneWidget);
    });

    testWidgets("a server that failed shows why", (WidgetTester tester) async {
      _tall(tester);
      host = FakeServerHost(const ServerState(run: ServerRunState.failed, detail: "Address already in use"));
      await tester.pumpWidget(diagnostics());
      await tester.pumpAndSettle();

      expect(find.text("1 thing needs a look."), findsOneWidget);
      expect(find.textContaining("Address already in use"), findsOneWidget);
    });

    testWidgets("Run the checks again picks up a fix", (WidgetTester tester) async {
      _tall(tester);
      accounts = InMemoryAccountRepository();
      await tester.pumpWidget(diagnostics());
      await tester.pumpAndSettle();
      expect(find.text("1 thing needs a look."), findsOneWidget);

      await accounts.create(Account(id: "a1", username: "admin", passwordHash: "x", createdAt: DateTime.utc(2026)));
      await tester.tap(find.text("Run the checks again"));
      await tester.pumpAndSettle();

      expect(find.text("Everything looks fine."), findsOneWidget);
    });

    testWidgets("Copy support bundle puts a shareable summary on the clipboard", (WidgetTester tester) async {
      _tall(tester);
      captureClipboard();
      host.savedConfig = const ServerConfig(allowNetworkAccess: true);
      await activity.addEvent(
        ActivityEvent(
          id: "e1",
          at: DateTime.utc(2026, 9, 20, 11),
          kind: ActivityKind.signInRefused,
          severity: ActivitySeverity.warning,
          message: "A sign-in was refused from 192.168.1.99.",
          address: "192.168.1.99",
        ),
      );
      await tester.pumpWidget(diagnostics());
      await tester.pumpAndSettle();

      await tester.tap(find.text("Copy support bundle"));
      await tester.pumpAndSettle();

      expect(copied, startsWith("VaultBox support bundle"));
      expect(copied, contains("App version: 0.1.0"));
      expect(copied, contains("Network access: on"));
      expect(copied, contains("[OK] Accounts"));
      expect(copied, contains("signInRefused"));
      expect(copied, isNot(contains("192.168.1.99")), reason: "no addresses in what people share");
      expect(copied, isNot(contains("Phone storage")), reason: "no storage names either");
      expect(find.textContaining("Support bundle copied"), findsOneWidget);
    });
  });
}

/// A tall screen: the checks and the buttons below them all get built.
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}
