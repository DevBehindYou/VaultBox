import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:qr_flutter/qr_flutter.dart";
import "package:vaultbox/app/app_state.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_activity_repository.dart";
import "package:vaultbox/data/repositories/in_memory_settings_repository.dart";
import "package:vaultbox/data/repositories/in_memory_share_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/activity.dart";
import "package:vaultbox/domain/entities/ftp_settings.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/repositories/account_repository.dart";
import "package:vaultbox/domain/repositories/activity_repository.dart";
import "package:vaultbox/domain/repositories/clock.dart";
import "package:vaultbox/domain/repositories/server_host.dart";
import "package:vaultbox/domain/repositories/settings_repository.dart";
import "package:vaultbox/domain/repositories/share_repository.dart";
import "package:vaultbox/domain/repositories/storage_root_repository.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/features/home/presentation/home_screen.dart";
import "package:vaultbox/platform/adapters/url_opener.dart";
import "package:vaultbox/platform/adapters/volume_stats_source.dart";

import "../helpers/fake_clock.dart";
import "../helpers/fake_server_host.dart";

final class _FakeStats implements VolumeStatsSource {
  _FakeStats([this.byRoot = const <String, VolumeStats>{}]);

  final Map<String, VolumeStats> byRoot;

  @override
  Future<VolumeStats?> statsFor(StorageRoot root) async => byRoot[root.id];
}

final class _RecordingOpener implements UrlOpener {
  final List<String> opened = <String>[];

  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return true;
  }
}

/// Home against a fake host and in-memory history: what the person sees for each
/// server state, and that every number on it is a real reading.
void main() {
  late FakeClock clock;
  late InMemoryActivityRepository activity;
  late InMemoryShareRepository shares;
  late InMemorySettingsRepository settings;
  late _RecordingOpener opener;
  String? copied;

  const StorageRoot phone = StorageRoot(
    id: "mem",
    displayName: "Phone storage",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://phone",
    capabilities: StorageCapabilities.fullLocal(),
    isDefault: true,
  );

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 9, 20, 12));
    activity = InMemoryActivityRepository();
    shares = InMemoryShareRepository();
    settings = InMemorySettingsRepository();
    opener = _RecordingOpener();
    copied = null;
  });

  Widget harness(
    FakeServerHost host, {
    bool withAdmin = true,
    List<StorageRoot> roots = const <StorageRoot>[phone],
    VolumeStatsSource? stats,
  }) {
    final GoRouter router = GoRouter(
      routes: <RouteBase>[
        GoRoute(path: "/", builder: (BuildContext c, GoRouterState s) => const HomeScreen()),
        for (final String path in <String>[
          "/settings/protocols",
          "/settings/storage",
          "/activity",
          "/share",
          "/admin/new",
          "/onboarding/welcome",
        ])
          GoRoute(path: path, builder: (BuildContext c, GoRouterState s) => Scaffold(body: Text("route:$path"))),
      ],
    );
    final AccountRepository accountRepository = InMemoryAccountRepository(
      withAdmin
          ? <Account>[Account(id: "1", username: "admin", passwordHash: "x", createdAt: DateTime.utc(2026))]
          : <Account>[],
    );
    final StorageRootRepository storageRootRepository = InMemoryStorageRootRepository(initial: roots);

    return MultiRepositoryProvider(
      providers: <RepositoryProvider<dynamic>>[
        RepositoryProvider<ServerHost>.value(value: host),
        RepositoryProvider<AccountRepository>.value(value: accountRepository),
        RepositoryProvider<StorageRootRepository>.value(value: storageRootRepository),
        RepositoryProvider<ActivityRepository>.value(value: activity),
        RepositoryProvider<ShareRepository>.value(value: shares),
        RepositoryProvider<SettingsRepository>.value(value: settings),
        RepositoryProvider<Clock>.value(value: clock),
        RepositoryProvider<VolumeStatsSource>.value(value: stats ?? _FakeStats()),
        RepositoryProvider<UrlOpener>.value(value: opener),
      ],
      child: MultiBlocProvider(
        providers: <BlocProvider<dynamic>>[
          BlocProvider<ServerStateCubit>(create: (BuildContext context) => ServerStateCubit(context.read<ServerHost>())),
          BlocProvider<ServerConfigCubit>(create: (BuildContext context) => ServerConfigCubit(context.read<ServerHost>())),
          BlocProvider<AdminExistsCubit>(create: (BuildContext context) => AdminExistsCubit(context.read<AccountRepository>())),
          BlocProvider<AccountsCubit>(create: (BuildContext context) => AccountsCubit(context.read<AccountRepository>())),
          BlocProvider<SharesCubit>(create: (BuildContext context) => SharesCubit(context.read<ShareRepository>())),
          BlocProvider<ActivityEventsCubit>(create: (BuildContext context) => ActivityEventsCubit(context.read<ActivityRepository>())),
          BlocProvider<ActivityTransfersCubit>(create: (BuildContext context) => ActivityTransfersCubit(context.read<ActivityRepository>())),
          BlocProvider<ActivityClientsCubit>(
            create: (BuildContext context) => ActivityClientsCubit(context.read<ActivityRepository>(), context.read<Clock>()),
          ),
          BlocProvider<StorageRootsCubit>(create: (BuildContext context) => StorageRootsCubit(context.read<StorageRootRepository>())),
          BlocProvider<RootStatsCubit>(
            create: (BuildContext context) => RootStatsCubit(context.read<StorageRootsCubit>(), context.read<VolumeStatsSource>()),
          ),
          BlocProvider<FtpSettingsCubit>(create: (BuildContext context) => FtpSettingsCubit(context.read<SettingsRepository>())),
        ],
        child: MaterialApp.router(theme: AuroraTheme.light(), routerConfig: router),
      ),
    );
  }

  Future<void> show(WidgetTester tester, FakeServerHost host, {bool withAdmin = true, List<StorageRoot>? roots, VolumeStatsSource? stats}) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(host, withAdmin: withAdmin, roots: roots ?? const <StorageRoot>[phone], stats: stats));
    await tester.pumpAndSettle();
  }

  void captureClipboard() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == "Clipboard.setData") copied = (call.arguments as Map<Object?, Object?>)["text"] as String?;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  const ServerState lan = ServerState(
    run: ServerRunState.running,
    endpoint: "https://192.168.1.5:8443/",
    endpoints: <String>["https://192.168.1.5:8443/", "http://192.168.1.5:8080/"],
  );

  group("the server card", () {
    testWidgets("stopped: a friendly invitation, and nothing reachable", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      expect(find.text("STANDBY"), findsOneWidget);
      expect(find.text("Your phone. Your files. Your server."), findsOneWidget);
      expect(find.textContaining("Nothing is reachable until you do"), findsOneWidget);
      expect(find.text("Start server"), findsOneWidget);
      expect(find.text("Protocol options"), findsOneWidget);
      expect(find.text("Stop Server"), findsNothing);
    });

    testWidgets("start goes live on this phone only; stop returns to standby", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host);

      await tester.tap(find.text("Start server"));
      await tester.pumpAndSettle();

      expect(host.starts, 1);
      expect(find.text("SERVER LIVE"), findsOneWidget);
      expect(find.text("Your phone is serving files."), findsOneWidget);
      expect(find.text("https://127.0.0.1:8443"), findsOneWidget);
      expect(find.textContaining("Only this phone can reach it"), findsOneWidget);
      expect(find.byTooltip("Show QR code"), findsNothing, reason: "nothing else can open a loopback address");
      expect(find.text("LAN IP:"), findsNothing);

      await tester.tap(find.text("Stop Server"));
      await tester.pumpAndSettle();

      expect(host.stops, 1);
      expect(find.text("STANDBY"), findsOneWidget);
    });

    testWidgets("reachable on the network: the address, the LAN IP and a QR code to scan", (WidgetTester tester) async {
      await show(tester, FakeServerHost(lan));

      expect(find.text("https://192.168.1.5:8443"), findsOneWidget, reason: "the encrypted address is the primary one");
      expect(find.text("LAN IP:"), findsOneWidget);
      expect(find.text("192.168.1.5:8443"), findsOneWidget);
      expect(find.textContaining("trusted network"), findsOneWidget);

      await tester.tap(find.byTooltip("Show QR code"));
      await tester.pumpAndSettle();
      expect(find.text("Open on another device"), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets("Copy address and Copy IP put the right text on the clipboard", (WidgetTester tester) async {
      captureClipboard();
      await show(tester, FakeServerHost(lan));

      await tester.tap(find.byTooltip("Copy address"));
      await tester.pumpAndSettle();
      expect(copied, "https://192.168.1.5:8443");
      expect(find.text("Address copied"), findsOneWidget);

      await tester.tap(find.text("Copy IP"));
      await tester.pumpAndSettle();
      expect(copied, "192.168.1.5:8443");
    });

    testWidgets("Open Portal opens the primary address in the browser", (WidgetTester tester) async {
      await show(tester, FakeServerHost(lan));

      await tester.tap(find.text("Open Portal"));
      await tester.pumpAndSettle();

      expect(opener.opened, <String>["https://192.168.1.5:8443/"]);
    });

    testWidgets("uptime comes from when the server last started", (WidgetTester tester) async {
      await activity.addEvent(
        ActivityEvent(
          id: "s",
          at: clock.now().subtract(const Duration(hours: 4, minutes: 28, seconds: 15)),
          kind: ActivityKind.serverStarted,
          message: "The server started.",
        ),
      );
      await show(tester, FakeServerHost(lan));

      expect(find.text("UP 04:28:15"), findsOneWidget);
    });

    testWidgets("while starting, it says so and offers no second start", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost()..holdInStarting = true;
      await show(tester, host);

      await tester.tap(find.text("Start server"));
      // The progress bar animates forever, so let a couple of frames pass rather than settling.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text("Starting the server…"), findsOneWidget);
      expect(find.text("Start server"), findsNothing);
      expect(host.starts, 1);
    });

    testWidgets("a failed start shows Try again and hides details behind a disclosure", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost(
        const ServerState(run: ServerRunState.failed, detail: "Couldn't open the local listener: port busy"),
      );
      await show(tester, host);

      expect(find.text("SERVER ERROR"), findsOneWidget);
      expect(find.text("The server couldn't start."), findsOneWidget);
      expect(find.text("Try again"), findsOneWidget);
      expect(find.text("Technical details"), findsOneWidget);

      await tester.tap(find.text("Try again"));
      await tester.pumpAndSettle();
      expect(host.starts, 1);
    });

    testWidgets("if asking the service to start throws, the person sees a message", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost()..failStart = const UnexpectedFailure(debugDetail: "x");
      await show(tester, host);

      await tester.tap(find.text("Start server"));
      await tester.pumpAndSettle();

      expect(find.text("Something went wrong. Please try again."), findsOneWidget);
      expect(find.text("STANDBY"), findsOneWidget);
    });

    testWidgets("Protocol options leads to Protocols & Network", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      await tester.tap(find.text("Protocol options"));
      await tester.pumpAndSettle();

      expect(find.text("route:/settings/protocols"), findsOneWidget);
    });
  });

  group("protocol chips", () {
    testWidgets("HTTPS and WebDAV by default; plain HTTP only when it is switched on", (WidgetTester tester) async {
      await show(tester, FakeServerHost());
      expect(find.text("HTTPS"), findsOneWidget);
      expect(find.text("8443"), findsOneWidget);
      expect(find.text("WebDAV"), findsOneWidget);
      expect(find.text("/dav"), findsOneWidget);
      expect(find.text("HTTP"), findsNothing);

      final FakeServerHost withHttp = FakeServerHost()..savedConfig = const ServerConfig(httpEnabled: true);
      await show(tester, withHttp);
      expect(find.text("HTTP"), findsOneWidget);
      expect(find.text("8080"), findsOneWidget);
    });

    testWidgets("FTP gets a chip once it is switched on", (WidgetTester tester) async {
      await show(tester, FakeServerHost());
      expect(find.text("FTPS"), findsNothing);

      settings = InMemorySettingsRepository(const FtpSettings(enabled: true).toMap());
      await show(tester, FakeServerHost());
      expect(find.text("FTPS"), findsOneWidget);
      expect(find.text("2121"), findsOneWidget);
    });

    testWidgets("each chip says whether it is listening, for screen readers too", (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await show(tester, FakeServerHost());
      expect(find.bySemanticsLabel("HTTPS 8443, off"), findsOneWidget);

      await show(tester, FakeServerHost(lan));
      expect(find.bySemanticsLabel("HTTPS 8443, listening"), findsOneWidget);
      semantics.dispose();
    });
  });

  group("the admin account card", () {
    testWidgets("shown until one exists, and leads to creating it", (WidgetTester tester) async {
      await show(tester, FakeServerHost(), withAdmin: false);

      expect(find.text("No admin account yet"), findsOneWidget);
      await tester.tap(find.text("Create admin account"));
      await tester.pumpAndSettle();
      expect(find.text("route:/admin/new"), findsOneWidget);
    });

    testWidgets("hidden once there is an admin", (WidgetTester tester) async {
      await show(tester, FakeServerHost());
      expect(find.text("No admin account yet"), findsNothing);
    });
  });

  group("storage", () {
    testWidgets("with nothing added it invites you to set storage up", (WidgetTester tester) async {
      await show(tester, FakeServerHost(), roots: const <StorageRoot>[]);

      expect(find.text("No storage yet"), findsOneWidget);
      await tester.tap(find.text("Set up storage"));
      await tester.pumpAndSettle();
      expect(find.text("route:/onboarding/welcome"), findsOneWidget);
    });

    testWidgets("real capacity: used of total, free, a meter, and each location", (WidgetTester tester) async {
      await show(
        tester,
        FakeServerHost(),
        stats: _FakeStats(<String, VolumeStats>{
          "mem": VolumeStats(freeBytes: 30 * 1024 * 1024 * 1024, totalBytes: 100 * 1024 * 1024 * 1024),
        }),
      );

      expect(find.text("Storage Capacity"), findsOneWidget);
      expect(find.text("70.0 GB"), findsWidgets);
      expect(find.text("used of 100.0 GB"), findsOneWidget);
      expect(find.text("30.0 GB free"), findsWidgets);
      expect(find.text("Phone storage"), findsOneWidget);
    });

    testWidgets("when capacity can't be read it lists the locations without inventing numbers", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      expect(find.text("Phone storage"), findsOneWidget);
      expect(find.textContaining("used of"), findsNothing);
    });

    testWidgets("Manage leads to Storage & Volumes", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      await tester.tap(find.text("Manage →"));
      await tester.pumpAndSettle();

      expect(find.text("route:/settings/storage"), findsOneWidget);
    });

    testWidgets("an offline location is marked", (WidgetTester tester) async {
      await show(
        tester,
        FakeServerHost(),
        roots: <StorageRoot>[phone.copyWith(isAvailable: false)],
      );

      expect(find.text("Offline"), findsOneWidget);
    });
  });

  group("at a glance", () {
    testWidgets("nothing going on: idle, and honest about it", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      expect(find.text("None online"), findsOneWidget);
      expect(find.text("Idle"), findsOneWidget);
      expect(find.text("0 active"), findsOneWidget);
      expect(find.text("1 account"), findsOneWidget);
      expect(find.textContaining("Nothing has happened yet"), findsOneWidget);
    });

    testWidgets("who is here, what is moving, and how many links are live", (WidgetTester tester) async {
      await activity.touchClient(
        ClientRecord(
          actor: "bob",
          address: "192.168.1.20",
          via: AccessVia.web,
          firstSeenAt: clock.now().subtract(const Duration(hours: 1)),
          lastSeenAt: clock.now().subtract(const Duration(minutes: 1)),
        ),
      );
      await activity.beginTransfer(
        TransferRecord(
          id: "t1",
          direction: TransferDirection.download,
          via: AccessVia.web,
          actor: "bob",
          name: "holiday.mp4",
          startedAt: clock.now().subtract(const Duration(minutes: 1)),
          updatedAt: clock.now(),
          bytes: 512,
          totalBytes: 1024,
        ),
      );
      await shares.add(
        Share(
          id: "s1",
          kind: ShareKind.download,
          rootId: "mem",
          path: "/x",
          isDirectory: false,
          createdBy: "1",
          createdAt: clock.now(),
          tokenHash: "h",
        ),
      );
      await show(tester, FakeServerHost(lan));

      expect(find.text("1 Online"), findsOneWidget);
      expect(find.text("bob"), findsOneWidget);
      expect(find.text("1 moving"), findsOneWidget);
      expect(find.text("1 active"), findsOneWidget);
      expect(find.text("holiday.mp4"), findsOneWidget);
      expect(find.text("50%"), findsOneWidget);
      expect(find.text("To bob"), findsOneWidget);
    });

    testWidgets("without transfers, Live Activity shows what happened lately", (WidgetTester tester) async {
      await activity.addEvent(
        ActivityEvent(
          id: "e",
          at: clock.now().subtract(const Duration(minutes: 3)),
          kind: ActivityKind.signedIn,
          message: "bob signed in.",
        ),
      );
      await show(tester, FakeServerHost());

      expect(find.text("bob signed in."), findsOneWidget);
      expect(find.text("3 minutes ago"), findsOneWidget);
    });

    testWidgets("tapping a tile goes to where its detail lives", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      await tester.tap(find.text("Idle"));
      await tester.pumpAndSettle();
      expect(find.text("route:/activity"), findsOneWidget);
    });
  });
}
