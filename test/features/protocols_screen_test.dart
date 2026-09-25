import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:vaultbox/app/app_state.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/core/design/aurora_widgets.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_settings_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/ftp_settings.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/repositories/account_repository.dart";
import "package:vaultbox/domain/repositories/server_host.dart";
import "package:vaultbox/domain/repositories/settings_repository.dart";
import "package:vaultbox/domain/repositories/storage_root_repository.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/features/settings/presentation/protocols_screen.dart";

import "../helpers/fake_server_host.dart";

/// Protocols & Network: the switches that used to sit on Home, now with ports,
/// the WebDAV address and a guide. Behaviour is unchanged where it was tested
/// before: asking before exposing anything, locking while the server runs.
void main() {
  String? copied;
  late InMemorySettingsRepository store;

  setUp(() {
    copied = null;
    store = InMemorySettingsRepository();
  });

  /// What is saved for FTP right now.
  Future<FtpSettings> savedFtp() async => FtpSettings.fromMap(await store.readAll());

  Widget harness(FakeServerHost host, {bool withAdmin = true, List<StorageRoot> roots = const <StorageRoot>[]}) {
    final GoRouter router = GoRouter(
      routes: <RouteBase>[
        GoRoute(path: "/", builder: (BuildContext c, GoRouterState s) => const ProtocolsScreen()),
        GoRoute(path: "/admin/new", builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text("route:/admin/new"))),
        GoRoute(path: "/settings/security", builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text("route:/settings/security"))),
      ],
    );
    final AccountRepository accounts = InMemoryAccountRepository(
      withAdmin
          ? <Account>[Account(id: "1", username: "admin", passwordHash: "x", createdAt: DateTime.utc(2026))]
          : <Account>[],
    );
    return MultiRepositoryProvider(
      providers: <RepositoryProvider<dynamic>>[
        RepositoryProvider<ServerHost>.value(value: host),
        RepositoryProvider<SettingsRepository>.value(value: store),
        RepositoryProvider<AccountRepository>.value(value: accounts),
        RepositoryProvider<StorageRootRepository>.value(value: InMemoryStorageRootRepository(initial: roots)),
      ],
      child: MultiBlocProvider(
        providers: <BlocProvider<dynamic>>[
          BlocProvider<ServerStateCubit>(create: (BuildContext context) => ServerStateCubit(context.read<ServerHost>())),
          BlocProvider<ServerConfigCubit>(create: (BuildContext context) => ServerConfigCubit(context.read<ServerHost>())),
          BlocProvider<AdminExistsCubit>(create: (BuildContext context) => AdminExistsCubit(context.read<AccountRepository>())),
          BlocProvider<FtpSettingsCubit>(create: (BuildContext context) => FtpSettingsCubit(context.read<SettingsRepository>())),
          BlocProvider<StorageRootsCubit>(create: (BuildContext context) => StorageRootsCubit(context.read<StorageRootRepository>())),
          BlocProvider<ProtocolStorageAccessCubit>(
            create: (BuildContext context) => ProtocolStorageAccessCubit(context.read<SettingsRepository>()),
          ),
        ],
        child: MaterialApp.router(theme: AuroraTheme.light(), routerConfig: router),
      ),
    );
  }

  Future<void> show(
    WidgetTester tester,
    FakeServerHost host, {
    bool withAdmin = true,
    List<StorageRoot> roots = const <StorageRoot>[],
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(host, withAdmin: withAdmin, roots: roots));
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
      expect(find.text("Off"), findsNWidgets(3), reason: "the service, plain HTTP and FTP are off");

      await tester.tap(switchIn("Server service"));
      await tester.pumpAndSettle();
      expect(host.starts, 1);
      expect(find.text("Running · this phone only"), findsOneWidget);

      await tester.tap(switchIn("Server service"));
      await tester.pumpAndSettle();
      expect(host.stops, 1);
      expect(find.text("Off"), findsNWidgets(3));
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
      expect(tester.widget<Switch>(switchIn("FTP / FTPS")).onChanged, isNull);
      expect(find.text("Stop the server to change this."), findsNWidgets(4));
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

      await tester.tap(find.text("Change").at(1)); // the HTTP port (HTTPS, HTTP, then FTP's two)
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

  group("FTP", () {
    testWidgets("is off by default, in the safest mode, with its ports shown", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      expect(isOn(tester, "FTP / FTPS"), isFalse);
      expect(find.text("FTPES"), findsOneWidget);
      expect(find.text("2121"), findsOneWidget);
      expect(find.text("50000–50050"), findsOneWidget);
      expect(find.textContaining("Anonymous access is never allowed"), findsOneWidget);
    });

    testWidgets("turning it on in an encrypted mode saves it without a warning", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      await tester.tap(switchIn("FTP / FTPS"));
      await tester.pumpAndSettle();

      expect(find.text("Use plain FTP?"), findsNothing);
      final FtpSettings saved = await savedFtp();
      expect(saved.enabled, isTrue);
      expect(saved.mode, FtpMode.explicitTls);
      expect(isOn(tester, "FTP / FTPS"), isTrue);
      expect(find.text("Ready"), findsNWidgets(2), reason: "HTTPS and FTP are set up but the server isn't running");
    });

    testWidgets("needs an admin account first", (WidgetTester tester) async {
      await show(tester, FakeServerHost(), withAdmin: false);

      await tester.tap(switchIn("FTP / FTPS"));
      await tester.pumpAndSettle();

      expect(find.text("Create the admin account first: FTP needs a login."), findsOneWidget);
      expect((await savedFtp()).enabled, isFalse);
    });

    testWidgets("plain FTP warns first and saves nothing until confirmed", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      await tester.tap(find.text("Plain FTP"));
      await tester.pumpAndSettle();
      expect(find.text("Use plain FTP?"), findsOneWidget);
      await tester.tap(find.text("Cancel"));
      await tester.pumpAndSettle();
      expect((await savedFtp()).mode, FtpMode.explicitTls);

      await tester.tap(find.text("Plain FTP"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Use plain FTP"));
      await tester.pumpAndSettle();
      expect((await savedFtp()).mode, FtpMode.plain);
      expect(find.text("FTP"), findsOneWidget, reason: "the tag now says plain FTP");
    });

    testWidgets("implicit FTPS is one tap, and is tagged FTPS", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      await tester.tap(find.text("Implicit FTPS"));
      await tester.pumpAndSettle();

      expect((await savedFtp()).mode, FtpMode.implicitTls);
      expect(find.text("FTPS"), findsOneWidget);
    });

    testWidgets("switching on while already plain still asks", (WidgetTester tester) async {
      store = InMemorySettingsRepository(const FtpSettings(mode: FtpMode.plain).toMap());
      await show(tester, FakeServerHost());

      await tester.tap(switchIn("FTP / FTPS"));
      await tester.pumpAndSettle();

      expect(find.text("Use plain FTP?"), findsOneWidget);
      expect((await savedFtp()).enabled, isFalse);
    });

    testWidgets("a new port is saved; bad ones and ones already in use are refused", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      Future<void> tryPort(String text) async {
        await tester.tap(find.text("Change").at(2));
        await tester.pumpAndSettle();
        expect(find.text("FTP port"), findsOneWidget);
        await tester.enterText(find.byType(TextField), text);
        await tester.tap(find.text("Save"));
        await tester.pumpAndSettle();
      }

      await tryPort("80");
      expect(find.text("Use a number from 1024 to 65535."), findsOneWidget);
      await tester.tap(find.text("Cancel"));
      await tester.pumpAndSettle();

      await tryPort("8443"); // the HTTPS port
      expect(find.text("That port is used by the web server."), findsOneWidget);
      await tester.tap(find.text("Cancel"));
      await tester.pumpAndSettle();

      await tryPort("50010"); // inside the file-transfer range
      expect(find.text("That port is inside the file-transfer range."), findsOneWidget);
      await tester.tap(find.text("Cancel"));
      await tester.pumpAndSettle();
      expect((await savedFtp()).port, 2121);

      await tryPort("2222");
      expect((await savedFtp()).port, 2222);
      expect(find.text("2222"), findsOneWidget);
    });

    testWidgets("the file-transfer range is saved when valid and refused when too small", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      Future<void> tryRange(String from, String to) async {
        await tester.tap(find.text("Change").at(3));
        await tester.pumpAndSettle();
        expect(find.text("File-transfer ports"), findsOneWidget);
        await tester.enterText(find.byType(TextField).first, from);
        await tester.enterText(find.byType(TextField).last, to);
        await tester.tap(find.text("Save"));
        await tester.pumpAndSettle();
      }

      await tryRange("51000", "51003");
      expect(find.text("Give it at least 10 ports."), findsOneWidget);
      await tester.tap(find.text("Cancel"));
      await tester.pumpAndSettle();
      expect((await savedFtp()).passiveStart, 50000);

      await tryRange("51000", "51100");
      expect((await savedFtp()).passiveStart, 51000);
      expect((await savedFtp()).passiveEnd, 51100);
      expect(find.text("51000–51100"), findsOneWidget);
    });

    testWidgets("the web-port dialog refuses a port FTP is using", (WidgetTester tester) async {
      store = InMemorySettingsRepository(const FtpSettings(enabled: true).toMap());
      await show(tester, FakeServerHost());

      await tester.tap(find.text("Change").first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), "2121");
      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();

      expect(find.text("That port is used by FTP."), findsOneWidget);
    });

    testWidgets("without network access it says only this phone can reach it", (WidgetTester tester) async {
      store = InMemorySettingsRepository(const FtpSettings(enabled: true).toMap());
      await show(tester, FakeServerHost());

      expect(find.textContaining("Only this phone can reach it"), findsOneWidget);
    });

    testWidgets("the guide fills in this phone's host and the chosen mode", (WidgetTester tester) async {
      await show(
        tester,
        FakeServerHost(const ServerState(run: ServerRunState.running, endpoint: "https://192.168.1.5:8443/")),
      );

      await tester.tap(find.text("How to connect with FTP"));
      await tester.pumpAndSettle();

      expect(find.text("Connect with FTP"), findsOneWidget);
      expect(find.text("ftp://192.168.1.5:2121"), findsOneWidget);
      expect(find.textContaining("Host: 192.168.1.5   Port: 2121"), findsOneWidget);
      expect(find.textContaining("Require explicit FTP over TLS"), findsWidgets);
    });
  });

  testWidgets("the Web Portal card links to the certificate", (WidgetTester tester) async {
    await show(tester, FakeServerHost());

    await tester.tap(find.text("Certificate and security"));
    await tester.pumpAndSettle();

    expect(find.text("route:/settings/security"), findsOneWidget);
  });

  group("storage access", () {
    const StorageRoot internal = StorageRoot(
      id: "internal",
      displayName: "Internal",
      backendType: StorageBackendType.memory,
      uriOrPath: "memory://internal",
      capabilities: StorageCapabilities.fullLocal(),
      isDefault: true,
    );
    const StorageRoot external = StorageRoot(
      id: "external",
      displayName: "SD card",
      backendType: StorageBackendType.memory,
      uriOrPath: "memory://external",
      capabilities: StorageCapabilities.fullLocal(),
    );

    /// The row for [rootName] inside the card that holds [cardTitle] — an
    /// `InkWell` (protocols_screen.dart's `_StorageAccessRow`, a private
    /// class this test file can't name directly), found by walking up from
    /// its own root-name text, scoped to the right card by walking up from
    /// the card's own title first.
    Finder rowFor(String cardTitle, String rootName) => find
        .ancestor(
          of: find.descendant(
            of: find.ancestor(of: find.text(cardTitle), matching: find.byType(AuroraCard)),
            matching: find.text(rootName),
          ),
          matching: find.byType(InkWell),
        )
        .first;

    bool isChecked(WidgetTester tester, String cardTitle, String rootName) {
      final Icon icon = tester.widget<Icon>(
        find.descendant(of: rowFor(cardTitle, rootName), matching: find.byType(Icon)),
      );
      return icon.icon == Icons.check_box;
    }

    testWidgets("with no storage yet, no protocol card shows a storage-access section", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      expect(find.text("STORAGE ACCESS"), findsNothing);
    });

    testWidgets("every root starts checked (unrestricted) once storage exists", (WidgetTester tester) async {
      await show(tester, FakeServerHost(), roots: <StorageRoot>[internal, external]);

      expect(find.text("STORAGE ACCESS"), findsNWidgets(4), reason: "Web Portal, Plain HTTP, WebDAV, FTP");
      for (final String card in <String>["Web Portal", "Plain HTTP", "WebDAV storage", "FTP / FTPS"]) {
        expect(isChecked(tester, card, "Internal"), isTrue, reason: card);
        expect(isChecked(tester, card, "SD card"), isTrue, reason: card);
      }
    });

    testWidgets("unchecking one root for one protocol persists an explicit set, others stay unrestricted", (WidgetTester tester) async {
      await show(tester, FakeServerHost(), roots: <StorageRoot>[internal, external]);

      await tester.tap(rowFor("FTP / FTPS", "SD card"));
      await tester.pumpAndSettle();

      expect(isChecked(tester, "FTP / FTPS", "SD card"), isFalse);
      expect(isChecked(tester, "FTP / FTPS", "Internal"), isTrue);
      // A protocol nobody has restricted yet still shows both as reachable.
      expect(isChecked(tester, "Web Portal", "SD card"), isTrue);

      final Map<String, String> saved = await store.readAll();
      expect(saved["protocol_access_ftp"], "internal");
      // Every save round-trips all four keys (SettingsRepository has no
      // delete, so "unrestricted" has to be a real written value, "*", not
      // just an absent key — see ProtocolStorageAccess). The other three
      // protocols were never touched, so they're written back unrestricted.
      expect(saved["protocol_access_web_portal_https"], "*");
      expect(saved["protocol_access_plain_http"], "*");
      expect(saved["protocol_access_webdav"], "*");
    });

    testWidgets("while the server runs, storage-access rows are locked too", (WidgetTester tester) async {
      await show(
        tester,
        FakeServerHost(const ServerState(run: ServerRunState.running, endpoint: "https://127.0.0.1:8443/")),
        roots: <StorageRoot>[internal],
      );

      expect(tester.widget<InkWell>(rowFor("Web Portal", "Internal")).onTap, isNull);
    });
  });
}
