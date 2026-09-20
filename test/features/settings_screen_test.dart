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
      final GoRouter router = GoRouter(
        initialLocation: "/settings",
        routes: <RouteBase>[
          GoRoute(
            path: "/settings",
            builder: (BuildContext c, GoRouterState s) => const SettingsScreen(),
            routes: <RouteBase>[
              GoRoute(path: "diagnostics", builder: (BuildContext c, GoRouterState s) => const DiagnosticsScreen()),
            ],
          ),
        ],
      );
      return scoped(MaterialApp.router(theme: AuroraTheme.light(), routerConfig: router));
    }

    testWidgets("lists what exists: Diagnostics and About", (WidgetTester tester) async {
      await tester.pumpWidget(settings());
      await tester.pumpAndSettle();

      expect(find.text("Settings"), findsOneWidget);
      expect(find.text("Diagnostics"), findsOneWidget);
      expect(find.text("About VaultBox"), findsOneWidget);
      expect(find.textContaining("Version 0.1.0"), findsOneWidget);
    });

    testWidgets("Diagnostics opens and runs the checks", (WidgetTester tester) async {
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
      host = FakeServerHost(const ServerState(run: ServerRunState.failed, detail: "Address already in use"));
      await tester.pumpWidget(diagnostics());
      await tester.pumpAndSettle();

      expect(find.text("1 thing needs a look."), findsOneWidget);
      expect(find.textContaining("Address already in use"), findsOneWidget);
    });

    testWidgets("Run the checks again picks up a fix", (WidgetTester tester) async {
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
