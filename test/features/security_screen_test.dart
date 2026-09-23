import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:vaultbox/app/app_state.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_activity_repository.dart";
import "package:vaultbox/data/repositories/in_memory_share_repository.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/activity.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/domain/repositories/account_repository.dart";
import "package:vaultbox/domain/repositories/activity_repository.dart";
import "package:vaultbox/domain/repositories/clock.dart";
import "package:vaultbox/domain/repositories/server_host.dart";
import "package:vaultbox/domain/repositories/share_repository.dart";
import "package:vaultbox/features/settings/presentation/security_screen.dart";

import "../helpers/fake_clock.dart";
import "../helpers/fake_server_host.dart";

/// Security & Sessions: the checklist reads the real settings, signing someone
/// out really ends their sessions, and the certificate is there to compare.
void main() {
  late FakeClock clock;
  late FakeServerHost host;
  late InMemoryAccountRepository accounts;
  late InMemoryActivityRepository activity;
  late InMemoryShareRepository shares;
  String? copied;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 9, 20, 12));
    host = FakeServerHost();
    accounts = InMemoryAccountRepository(<Account>[
      Account(id: "a1", username: "admin", passwordHash: "x", createdAt: DateTime.utc(2026)),
      Account(id: "m1", username: "bob", passwordHash: "x", createdAt: DateTime.utc(2026), role: AccountRole.member),
    ]);
    activity = InMemoryActivityRepository();
    shares = InMemoryShareRepository();
    copied = null;
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final GoRouter router = GoRouter(
      routes: <RouteBase>[
        GoRoute(path: "/", builder: (BuildContext c, GoRouterState s) => const SecurityScreen()),
        GoRoute(path: "/activity", builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text("route:/activity"))),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: <RepositoryProvider<dynamic>>[
          RepositoryProvider<ServerHost>.value(value: host),
          RepositoryProvider<AccountRepository>.value(value: accounts),
          RepositoryProvider<ActivityRepository>.value(value: activity),
          RepositoryProvider<ShareRepository>.value(value: shares),
          RepositoryProvider<Clock>.value(value: clock),
        ],
        child: MultiBlocProvider(
          providers: <BlocProvider<dynamic>>[
            BlocProvider<ServerConfigCubit>(create: (BuildContext context) => ServerConfigCubit(context.read<ServerHost>())),
            BlocProvider<TlsFingerprintCubit>(create: (BuildContext context) => TlsFingerprintCubit(context.read<ServerHost>())),
            BlocProvider<AdminExistsCubit>(create: (BuildContext context) => AdminExistsCubit(context.read<AccountRepository>())),
            BlocProvider<AccountsCubit>(create: (BuildContext context) => AccountsCubit(context.read<AccountRepository>())),
            BlocProvider<SharesCubit>(create: (BuildContext context) => SharesCubit(context.read<ShareRepository>())),
            BlocProvider<ActivityEventsCubit>(create: (BuildContext context) => ActivityEventsCubit(context.read<ActivityRepository>())),
            BlocProvider<ActivityClientsCubit>(
              create: (BuildContext context) => ActivityClientsCubit(context.read<ActivityRepository>(), context.read<Clock>()),
            ),
          ],
          child: MaterialApp.router(theme: AuroraTheme.light(), routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ClientRecord client(String actor, String address, Duration lastSeen, {AccessVia via = AccessVia.web}) => ClientRecord(
    actor: actor,
    address: address,
    via: via,
    firstSeenAt: clock.now().subtract(const Duration(hours: 2)),
    lastSeenAt: clock.now().subtract(lastSeen),
  );

  ActivityEvent refused(int id, Duration ago) => ActivityEvent(
    id: "e$id",
    at: clock.now().subtract(ago),
    kind: ActivityKind.signInRefused,
    severity: ActivitySeverity.warning,
    message: "A sign-in was refused.",
  );

  void captureClipboard() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == "Clipboard.setData") copied = (call.arguments as Map<Object?, Object?>)["text"] as String?;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  group("the protection checklist", () {
    testWidgets("a default phone has everything in place", (WidgetTester tester) async {
      await show(tester);

      expect(find.text("Security & Sessions"), findsOneWidget);
      expect(find.text("6 of 6 protections fully in place."), findsOneWidget);
      expect(find.text("Protected"), findsOneWidget);
      expect(find.text("Encryption"), findsOneWidget);
      expect(find.textContaining("HTTPS is the only way in"), findsOneWidget);
    });

    testWidgets("turning plain HTTP on is called out", (WidgetTester tester) async {
      host.savedConfig = const ServerConfig(httpEnabled: true);
      await show(tester);

      expect(find.text("5 of 6 protections fully in place."), findsOneWidget);
      expect(find.text("Review"), findsOneWidget);
      expect(find.textContaining("Plain HTTP is on"), findsOneWidget);
    });

    testWidgets("a link without a password is called out", (WidgetTester tester) async {
      await shares.add(
        Share(
          id: "s",
          kind: ShareKind.download,
          rootId: "r",
          path: "/x",
          isDirectory: false,
          createdBy: "a1",
          createdAt: clock.now(),
          tokenHash: "h",
        ),
      );
      await show(tester);

      expect(find.textContaining("1 active link has no password"), findsOneWidget);
    });
  });

  group("signed-in devices", () {
    testWidgets("nobody: an empty state", (WidgetTester tester) async {
      await show(tester);

      expect(find.text("Nobody is signed in"), findsOneWidget);
    });

    testWidgets("lists each client with how it connected and how recently", (WidgetTester tester) async {
      await activity.touchClient(client("bob", "192.168.1.20", const Duration(minutes: 1)));
      await activity.touchClient(client("bob", "192.168.1.30", const Duration(hours: 3), via: AccessVia.webdav));
      await show(tester);

      expect(find.text("Browser · 192.168.1.20"), findsOneWidget);
      expect(find.text("Active now"), findsOneWidget);
      expect(find.text("WebDAV · 192.168.1.30"), findsOneWidget);
      expect(find.text("Last active 3 hours ago"), findsOneWidget);
    });

    testWidgets("Sign out asks first, then ends that person's sessions everywhere", (WidgetTester tester) async {
      await activity.touchClient(client("bob", "192.168.1.20", const Duration(minutes: 1)));
      await show(tester);

      await tester.tap(find.text("Sign out"));
      await tester.pumpAndSettle();
      expect(find.text("Sign bob out?"), findsOneWidget);
      await tester.tap(find.text("Keep"));
      await tester.pumpAndSettle();
      expect((await accounts.findByUsername("bob"))!.credentialVersion, 0, reason: "cancelling changes nothing");

      await tester.tap(find.text("Sign out"));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, "Sign out"));
      await tester.pumpAndSettle();

      expect((await accounts.findByUsername("bob"))!.credentialVersion, 1, reason: "a new version kills every session");
      expect((await accounts.findByUsername("admin"))!.credentialVersion, 0, reason: "and only theirs");
      expect(find.text("bob was signed out everywhere."), findsOneWidget);
    });

    testWidgets("Sign everyone out ends every account's sessions, and keeps the accounts", (WidgetTester tester) async {
      await activity.touchClient(client("bob", "192.168.1.20", const Duration(minutes: 1)));
      await show(tester);

      await tester.tap(find.text("Sign everyone out"));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, "Sign everyone out"));
      await tester.pumpAndSettle();

      expect((await accounts.findByUsername("bob"))!.credentialVersion, 1);
      expect((await accounts.findByUsername("admin"))!.credentialVersion, 1);
      expect(await accounts.count(), 2);
      expect(find.text("Everyone was signed out."), findsOneWidget);
    });
  });

  group("guessing protection", () {
    testWidgets("counts refused sign-ins from the last week only", (WidgetTester tester) async {
      await activity.addEvent(refused(1, const Duration(hours: 1)));
      await activity.addEvent(refused(2, const Duration(days: 3)));
      await activity.addEvent(refused(3, const Duration(days: 8)));
      await show(tester);

      expect(find.text("2 refused sign-in events in the last 7 days."), findsOneWidget);
    });

    testWidgets("none is good news, and the log is one tap away", (WidgetTester tester) async {
      await show(tester);

      expect(find.text("No refused sign-ins in the last 7 days."), findsOneWidget);
      await tester.tap(find.text("Open the Activity log"));
      await tester.pumpAndSettle();
      expect(find.text("route:/activity"), findsOneWidget);
    });
  });

  group("the certificate", () {
    testWidgets("shows the fingerprint to compare with the browser, and copies it", (WidgetTester tester) async {
      captureClipboard();
      await show(tester);

      expect(find.text(FakeServerHost.fingerprint), findsOneWidget);

      await tester.tap(find.text("Copy fingerprint"));
      await tester.pumpAndSettle();

      expect(copied, FakeServerHost.fingerprint);
      expect(find.text("Fingerprint copied"), findsOneWidget);
    });
  });
}
