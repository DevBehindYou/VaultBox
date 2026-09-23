import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:qr_flutter/qr_flutter.dart";
import "package:vaultbox/app/app_state.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/core/design/aurora_widgets.dart";
import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_share_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/access_rule.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/models/file_ref.dart";
import "package:vaultbox/domain/repositories/account_repository.dart";
import "package:vaultbox/domain/repositories/clock.dart";
import "package:vaultbox/domain/repositories/file_repository.dart";
import "package:vaultbox/domain/repositories/id_generator.dart";
import "package:vaultbox/domain/repositories/server_host.dart";
import "package:vaultbox/domain/repositories/share_repository.dart";
import "package:vaultbox/domain/repositories/storage_root_repository.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/security/permission.dart";
import "package:vaultbox/domain/security/share_tokens.dart";
import "package:vaultbox/domain/usecases/create_share.dart";
import "package:vaultbox/domain/usecases/manage_accounts.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/features/share/presentation/add_person_screen.dart";
import "package:vaultbox/features/share/presentation/create_share_dialog.dart";
import "package:vaultbox/features/share/presentation/person_screen.dart";
import "package:vaultbox/features/share/presentation/share_screen.dart";

import "../helpers/fake_clock.dart";
import "../helpers/fake_password_hasher.dart";
import "../helpers/fake_server_host.dart";

final class _Ids implements IdGenerator {
  int _next = 0;

  @override
  String newId() => "gen${_next++}";
}

/// The Share tab, the people screens and the make-a-link flow, all on in-memory
/// parts (no database, no server).
void main() {
  const StorageRoot root = StorageRoot(
    id: "mem",
    displayName: "Test storage",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://test",
    capabilities: StorageCapabilities.fullLocal(),
    isDefault: true,
  );

  late FakeClock clock;
  late InMemoryAccountRepository accounts;
  late InMemoryShareRepository shares;
  late FakeServerHost host;
  late MemoryStorageBackend backend;
  late FakePasswordHasher hasher;

  final Account admin = Account(id: "a1", username: "admin", passwordHash: "fake:x", createdAt: DateTime.utc(2026));
  final Account bob = Account(
    id: "m1",
    username: "bob",
    passwordHash: "fake:x",
    createdAt: DateTime.utc(2026, 2),
    role: AccountRole.member,
    rules: const <AccessRule>[
      AccessRule(id: "r1", accountId: "m1", rootId: "mem", pathPrefix: "/Photos", permissions: AccessRule.readWrite),
      AccessRule(id: "r2", accountId: "m1", rootId: "mem", pathPrefix: "/", permissions: AccessRule.readOnly),
    ],
  );

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 9, 20, 12));
    accounts = InMemoryAccountRepository(<Account>[admin, bob]);
    shares = InMemoryShareRepository();
    host = FakeServerHost();
    hasher = FakePasswordHasher();
    backend = MemoryStorageBackend(id: root.id)
      ..seedFile("/readme.txt", utf8.encode("hello"))
      ..seedDirectory("/Inbox")
      ..seedDirectory("/Photos");
  });

  Widget scoped({required Widget child, InMemoryAccountRepository? accountRepo}) {
    final InMemoryAccountRepository accountRepository = accountRepo ?? accounts;
    final StorageRootRepository roots = InMemoryStorageRootRepository(initial: <StorageRoot>[root]);
    final BackendRegistry registry = BackendRegistry()..register(backend);
    final FileRepository files = FileRepositoryImpl(resolveBackend: registry.forRoot);
    const Authorizer authorizer = AclAuthorizer();
    final IdGenerator ids = _Ids();

    return MultiRepositoryProvider(
      providers: <RepositoryProvider<dynamic>>[
        RepositoryProvider<AccountRepository>.value(value: accountRepository),
        RepositoryProvider<ShareRepository>.value(value: shares),
        RepositoryProvider<StorageRootRepository>.value(value: roots),
        RepositoryProvider<ServerHost>.value(value: host),
        RepositoryProvider<Clock>.value(value: clock),
        RepositoryProvider<CreateUserAccount>.value(
          value: CreateUserAccount(accountRepository, hasher, ids, clock),
        ),
        RepositoryProvider<SetAccountEnabled>.value(value: SetAccountEnabled(accountRepository)),
        RepositoryProvider<ChangePassword>.value(value: ChangePassword(accountRepository, hasher)),
        RepositoryProvider<DeleteAccount>.value(value: DeleteAccount(accountRepository, shares)),
        RepositoryProvider<SetAccessRules>.value(value: SetAccessRules(accountRepository, ids)),
        RepositoryProvider<CreateShare>.value(
          value: CreateShare(
            roots: roots,
            files: files,
            shares: shares,
            hasher: hasher,
            ids: ids,
            clock: clock,
            authorizer: authorizer,
          ),
        ),
      ],
      child: MultiBlocProvider(
        providers: <BlocProvider<dynamic>>[
          BlocProvider<SharesCubit>(create: (BuildContext context) => SharesCubit(context.read<ShareRepository>())),
          BlocProvider<AccountsCubit>(
            create: (BuildContext context) => AccountsCubit(context.read<AccountRepository>()),
          ),
          BlocProvider<OwnerAccountCubit>(
            create: (BuildContext context) => OwnerAccountCubit(context.read<AccountsCubit>()),
          ),
          BlocProvider<StorageRootsCubit>(
            create: (BuildContext context) => StorageRootsCubit(context.read<StorageRootRepository>()),
          ),
          BlocProvider<ServerStateCubit>(
            create: (BuildContext context) => ServerStateCubit(context.read<ServerHost>()),
          ),
        ],
        child: child,
      ),
    );
  }

  Widget app({InMemoryAccountRepository? accountRepo}) {
    final GoRouter router = GoRouter(
      initialLocation: "/share",
      routes: <RouteBase>[
        GoRoute(path: "/share", builder: (BuildContext c, GoRouterState s) => const ShareScreen()),
        GoRoute(
          path: "/people/new",
          builder: (BuildContext c, GoRouterState s) => AddPersonScreen(
            onDone: (BuildContext context, Account account) => context.pushReplacement("/people/${account.id}"),
          ),
        ),
        GoRoute(
          path: "/people/:id",
          builder: (BuildContext c, GoRouterState s) => PersonScreen(
            accountId: s.pathParameters["id"]!,
            onRemoved: (BuildContext context) => context.pop(),
          ),
        ),
      ],
    );
    return scoped(
      accountRepo: accountRepo,
      child: MaterialApp.router(theme: AuroraTheme.light(), routerConfig: router),
    );
  }

  Share share({
    String id = "s1",
    ShareKind kind = ShareKind.download,
    String? label = "Holiday photos",
    DateTime? expires,
    int? maxUses,
    int used = 0,
    String? password,
  }) => Share(
    id: id,
    kind: kind,
    rootId: "mem",
    path: "/Photos",
    isDirectory: true,
    createdBy: "a1",
    createdAt: clock.now(),
    tokenHash: "hash-$id",
    label: label,
    expiresAt: expires,
    passwordHash: password,
    maxUses: maxUses,
    useCount: used,
  );

  Future<void> openPeople(WidgetTester tester) async {
    await tester.tap(find.text("People"));
    await tester.pumpAndSettle();
  }

  Future<void> setText(WidgetTester tester, String label, String text) async {
    await tester.enterText(find.widgetWithText(TextField, label), text);
    await tester.pump();
  }

  group("Links", () {
    testWidgets("with none, explains how to make one", (WidgetTester tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.textContaining("No links yet"), findsOneWidget);
    });

    testWidgets("lists each link with its kind, state, limits and password", (WidgetTester tester) async {
      await shares.add(share(maxUses: 5, used: 1, password: r"$argon2id$x", expires: clock.now().add(const Duration(days: 3))));
      await shares.add(
        share(id: "s2", kind: ShareKind.upload, label: "Inbox", expires: clock.now().subtract(const Duration(days: 1))),
      );

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text("Holiday photos"), findsOneWidget);
      expect(find.textContaining("1 of 5 downloads"), findsOneWidget);
      expect(find.textContaining("Expires in 3 days"), findsOneWidget);
      expect(find.text("Active"), findsOneWidget);
      expect(find.text("Password"), findsOneWidget);
      expect(find.text("Inbox"), findsOneWidget);
      expect(find.text("Upload"), findsOneWidget);
      expect(find.text("Expired"), findsWidgets);
    });

    testWidgets("turning a link off asks first, then it is gone for good", (WidgetTester tester) async {
      await shares.add(share());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip("Turn this link off"));
      await tester.pumpAndSettle();
      expect(find.text("Turn this link off?"), findsOneWidget);

      await tester.tap(find.text("Keep"));
      await tester.pumpAndSettle();
      expect(await shares.list(), hasLength(1), reason: "cancelling changes nothing");

      await tester.tap(find.byTooltip("Turn this link off"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Turn off"));
      await tester.pumpAndSettle();

      expect(await shares.list(), isEmpty);
      expect(find.textContaining("No links yet"), findsOneWidget);
    });
  });

  group("People", () {
    testWidgets("lists accounts with role, off-state and how many folders", (WidgetTester tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openPeople(tester);

      expect(find.text("admin"), findsOneWidget);
      expect(find.text("bob"), findsOneWidget);
      expect(find.text("Admin"), findsOneWidget);
      expect(find.text("Member"), findsOneWidget);
      expect(find.text("2 folders"), findsOneWidget);
    });

    testWidgets("a turned-off account says so", (WidgetTester tester) async {
      await accounts.setEnabled("m1", enabled: false);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openPeople(tester);

      expect(find.text("Turned off"), findsOneWidget);
    });

    testWidgets("with no accounts at all, points at the Home tab", (WidgetTester tester) async {
      await tester.pumpWidget(app(accountRepo: InMemoryAccountRepository()));
      await tester.pumpAndSettle();
      await openPeople(tester);

      expect(find.textContaining("Create the admin account on the Home tab"), findsOneWidget);
      expect(find.text("Add a person"), findsNothing);
    });

    group("adding someone", () {
      Future<void> open(WidgetTester tester) async {
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        await openPeople(tester);
        await tester.tap(find.text("Add a person"));
        await tester.pumpAndSettle();
      }

      bool submitEnabled(WidgetTester tester) =>
          tester.widget<AuroraPrimaryButton>(find.widgetWithText(AuroraPrimaryButton, "Add person")).onPressed != null;

      testWidgets("the button waits for a valid name and a matching password", (WidgetTester tester) async {
        await open(tester);
        expect(submitEnabled(tester), isFalse);

        await setText(tester, "Username", "carol");
        await setText(tester, "Password", "a fine long password");
        expect(submitEnabled(tester), isFalse, reason: "not confirmed yet");

        await setText(tester, "Confirm password", "something else entirely");
        expect(find.text("The passwords don't match."), findsOneWidget);
        expect(submitEnabled(tester), isFalse);

        await setText(tester, "Confirm password", "a fine long password");
        expect(submitEnabled(tester), isTrue);
      });

      testWidgets("policy problems show while typing", (WidgetTester tester) async {
        await open(tester);
        await setText(tester, "Username", "x");
        await setText(tester, "Password", "short");

        expect(find.text("Use at least 3 characters."), findsOneWidget);
        expect(find.text("Use at least 12 characters."), findsOneWidget);
      });

      testWidgets("creates a member and lands on their page", (WidgetTester tester) async {
        await open(tester);
        await setText(tester, "Username", "Carol");
        await setText(tester, "Password", "a fine long password");
        await setText(tester, "Confirm password", "a fine long password");
        await tester.tap(find.text("Add person"));
        await tester.pumpAndSettle();

        final Account? carol = await accounts.findByUsername("carol");
        expect(carol, isNotNull);
        expect(carol!.role, AccountRole.member);
        expect(carol.passwordHash, "fake:a fine long password");
        expect(find.text("carol"), findsOneWidget, reason: "now on their page");
        expect(find.textContaining("None yet"), findsOneWidget);
      });

      testWidgets("a name that's taken is explained, not crashed on", (WidgetTester tester) async {
        await open(tester);
        await setText(tester, "Username", "bob");
        await setText(tester, "Password", "a fine long password");
        await setText(tester, "Confirm password", "a fine long password");
        await tester.tap(find.text("Add person"));
        await tester.pumpAndSettle();

        expect(find.text("That username is already taken."), findsOneWidget);
        expect(await accounts.count(), 2);
      });
    });
  });

  group("a person's page", () {
    Future<void> openBob(WidgetTester tester) async {
      // A tall screen: the page is a long list and its last button must be built.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openPeople(tester);
      await tester.tap(find.text("bob"));
      await tester.pumpAndSettle();
    }

    testWidgets("shows their folders with plain-words permissions", (WidgetTester tester) async {
      await openBob(tester);

      expect(find.text("Folders they can reach"), findsOneWidget);
      expect(find.text("Test storage · /Photos"), findsOneWidget);
      expect(find.text("View · Add & edit"), findsOneWidget);
      expect(find.text("Test storage · everything"), findsOneWidget);
      expect(find.text("View"), findsOneWidget);
    });

    testWidgets("the sign-in switch turns access off and back on", (WidgetTester tester) async {
      await openBob(tester);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect((await accounts.findById("m1"))!.isEnabled, isFalse);
      expect(find.text("Turned off"), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect((await accounts.findById("m1"))!.isEnabled, isTrue);
    });

    testWidgets("a new password needs to match and ends their sessions", (WidgetTester tester) async {
      await openBob(tester);

      await tester.tap(find.text("Set a new password"));
      await tester.pumpAndSettle();
      expect(find.text("New password for bob"), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, "New password"), "brand new long password");
      await tester.enterText(find.widgetWithText(TextField, "Confirm password"), "brand new long passwor");
      await tester.pump();
      expect(find.text("The passwords don't match."), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, "Change password")).onPressed, isNull);

      await tester.enterText(find.widgetWithText(TextField, "Confirm password"), "brand new long password");
      await tester.pump();
      await tester.tap(find.text("Change password"));
      await tester.pumpAndSettle();

      final Account after = (await accounts.findById("m1"))!;
      expect(after.passwordHash, "fake:brand new long password");
      expect(after.credentialVersion, 1);
      expect(find.textContaining("Password changed"), findsOneWidget);
    });

    testWidgets("a folder can be taken away", (WidgetTester tester) async {
      await openBob(tester);

      await tester.tap(find.byTooltip("Remove this folder").first);
      await tester.pumpAndSettle();

      expect((await accounts.findById("m1"))!.rules.map((AccessRule r) => r.pathPrefix), <String>["/"]);
      expect(find.text("Test storage · /Photos"), findsNothing);
    });

    testWidgets("a folder can be given: pick it, choose what they may do", (WidgetTester tester) async {
      await openBob(tester);
      await tester.tap(find.byTooltip("Remove this folder").first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip("Remove this folder").first);
      await tester.pumpAndSettle();
      expect(find.textContaining("None yet"), findsOneWidget);

      await tester.tap(find.text("Give access to a folder"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Photos"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Select this folder"));
      await tester.pumpAndSettle();

      expect(find.text("Access to “Photos”"), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, "Delete")).onChanged, isNull, reason: "delete needs add & change");
      await tester.tap(find.text("Add and change"));
      await tester.pump();
      await tester.tap(find.text("Delete"));
      await tester.pump();
      await tester.tap(find.text("Give access"));
      await tester.pumpAndSettle();

      final List<AccessRule> rules = (await accounts.findById("m1"))!.rules;
      expect(rules.single.pathPrefix, "/Photos");
      expect(rules.single.permissions.map((Permission p) => p.name).toSet(), <String>{"read", "write", "delete"});
      expect(find.text("View · Add & edit · Delete"), findsOneWidget);
    });

    testWidgets("removing someone asks first and returns to the list", (WidgetTester tester) async {
      await openBob(tester);

      await tester.tap(find.text("Remove this person"));
      await tester.pumpAndSettle();
      expect(find.text("Remove bob?"), findsOneWidget);
      await tester.tap(find.text("Keep"));
      await tester.pumpAndSettle();
      expect(await accounts.findById("m1"), isNotNull);

      await tester.tap(find.text("Remove this person"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Remove"));
      await tester.pumpAndSettle();

      expect(await accounts.findById("m1"), isNull);
      expect(find.text("bob"), findsNothing);
      expect(find.text("Add a person"), findsOneWidget, reason: "back on the people list");
    });

    testWidgets("the only admin can't be removed, and has no folder settings", (WidgetTester tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openPeople(tester);
      await tester.tap(find.text("admin"));
      await tester.pumpAndSettle();

      expect(find.textContaining("Admins can reach everything"), findsOneWidget);
      expect(find.text("Give access to a folder"), findsNothing);

      await tester.tap(find.text("Remove this person"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Remove"));
      await tester.pumpAndSettle();

      expect(find.text("This is the only admin — it can't be removed."), findsOneWidget);
      expect(await accounts.findById("a1"), isNotNull);
    });
  });

  group("making a link", () {
    String? copied;

    setUp(() {
      copied = null;
    });

    Widget launcher({required ShareKind kind, required String path, String name = "readme.txt", InMemoryAccountRepository? accountRepo}) {
      return scoped(
        accountRepo: accountRepo,
        child: MaterialApp(
          theme: AuroraTheme.light(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showCreateShareFlow(
                    context,
                    target: FileRef(root: root, path: StoragePath.parseDecoded(root.id, path)),
                    kind: kind,
                    itemName: name,
                  ),
                  child: const Text("Open"),
                ),
              ),
            ),
          ),
        ),
      );
    }

    void captureClipboard() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
        if (call.method == "Clipboard.setData") copied = (call.arguments as Map<Object?, Object?>)["text"] as String?;
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    }

    Future<void> serverRuns(WidgetTester tester, List<String> endpoints) async {
      host.emit(ServerState(run: ServerRunState.running, endpoint: endpoints.first, endpoints: endpoints));
      await tester.pumpAndSettle();
    }

    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.text("Open"));
      await tester.pumpAndSettle();
    }

    testWidgets("a download link: options, then the address with a QR code", (WidgetTester tester) async {
      captureClipboard();
      await tester.pumpWidget(launcher(kind: ShareKind.download, path: "/readme.txt"));
      await serverRuns(tester, <String>["https://192.168.1.5:8443/"]);
      await openDialog(tester);

      expect(find.text("Share a link"), findsOneWidget);
      expect(find.textContaining("can download “readme.txt”"), findsOneWidget);
      expect(find.text("7 days"), findsOneWidget, reason: "a sensible default expiry");

      await tester.tap(find.text("Create link"));
      await tester.pumpAndSettle();

      expect(find.text("Link ready"), findsOneWidget);
      final String address = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
      expect(address, startsWith("https://192.168.1.5:8443/s/"));
      final String token = address.split("/s/").last;
      expect(ShareTokens.looksValid(token), isTrue);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.textContaining("can't be shown again"), findsOneWidget);
      expect(find.textContaining("not encrypted"), findsNothing);

      final Share stored = (await shares.list()).single;
      expect(stored.tokenHash, ShareTokens.hash(token));
      expect(stored.kind, ShareKind.download);
      expect(stored.path, "/readme.txt");
      expect(stored.label, "readme.txt");
      expect(stored.expiresAt, clock.now().add(const Duration(days: 7)));
      expect(stored.hasPassword, isFalse);

      await tester.tap(find.text("Copy"));
      await tester.pumpAndSettle();
      expect(copied, address);
    });

    testWidgets("a password and a limit are applied — and a short password is refused on the spot", (WidgetTester tester) async {
      await tester.pumpWidget(launcher(kind: ShareKind.download, path: "/readme.txt"));
      await serverRuns(tester, <String>["https://192.168.1.5:8443/"]);
      await openDialog(tester);

      await setText(tester, "Password (optional)", "abc");
      expect(find.text("Use at least 6 characters."), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, "Create link")).onPressed, isNull);

      await setText(tester, "Password (optional)", "hunter22");
      await setText(tester, "Most downloads (optional)", "3");
      await tester.tap(find.text("Create link"));
      await tester.pumpAndSettle();

      expect(find.textContaining("asks for the password you chose"), findsOneWidget);
      final Share stored = (await shares.list()).single;
      expect(stored.passwordHash, "fake:hunter22");
      expect(stored.maxUses, 3);
    });

    testWidgets("a limit of zero is refused", (WidgetTester tester) async {
      await tester.pumpWidget(launcher(kind: ShareKind.download, path: "/readme.txt"));
      await openDialog(tester);

      await setText(tester, "Most downloads (optional)", "0");
      expect(find.text("Enter a whole number, 1 or more."), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, "Create link")).onPressed, isNull);
    });

    testWidgets("an upload request asks for a file-size limit and uses /u/", (WidgetTester tester) async {
      await tester.pumpWidget(launcher(kind: ShareKind.upload, path: "/Inbox", name: "Inbox"));
      await serverRuns(tester, <String>["https://192.168.1.5:8443/"]);
      await openDialog(tester);

      expect(find.text("Ask for files"), findsOneWidget);
      expect(find.text("Biggest file"), findsOneWidget);
      expect(find.text("100 MB"), findsOneWidget);
      await setText(tester, "Most files (optional)", "10");
      await tester.tap(find.text("Create link"));
      await tester.pumpAndSettle();

      final String address = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
      expect(address, contains("/u/"));
      final Share stored = (await shares.list()).single;
      expect(stored.kind, ShareKind.upload);
      expect(stored.maxFileBytes, 100 * 1024 * 1024);
      expect(stored.maxUses, 10);
    });

    testWidgets("with the server off there is no address yet, and no QR code", (WidgetTester tester) async {
      await tester.pumpWidget(launcher(kind: ShareKind.download, path: "/readme.txt"));
      await tester.pumpAndSettle();
      await openDialog(tester);
      await tester.tap(find.text("Create link"));
      await tester.pumpAndSettle();

      expect(find.text("Link ready"), findsOneWidget);
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).data, startsWith("…/s/"));
      expect(find.textContaining("server isn't running"), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      expect(await shares.list(), hasLength(1), reason: "the link exists even so");
    });

    testWidgets("an unencrypted address is flagged", (WidgetTester tester) async {
      await tester.pumpWidget(launcher(kind: ShareKind.download, path: "/readme.txt"));
      await serverRuns(tester, <String>["http://192.168.1.5:8080/"]);
      await openDialog(tester);
      await tester.tap(find.text("Create link"));
      await tester.pumpAndSettle();

      expect(find.textContaining("not encrypted"), findsOneWidget);
    });

    testWidgets("something that can't be shared explains why", (WidgetTester tester) async {
      await tester.pumpWidget(launcher(kind: ShareKind.download, path: "/missing.txt", name: "missing.txt"));
      await openDialog(tester);
      await tester.tap(find.text("Create link"));
      await tester.pumpAndSettle();

      expect(find.text("That item doesn't exist."), findsOneWidget);
      expect(find.text("Share a link"), findsOneWidget, reason: "still open, so they can cancel");
      expect(await shares.list(), isEmpty);
    });

    testWidgets("without an admin account it says to create one first", (WidgetTester tester) async {
      await tester.pumpWidget(launcher(kind: ShareKind.download, path: "/readme.txt", accountRepo: InMemoryAccountRepository()));
      await openDialog(tester);
      await tester.tap(find.text("Create link"));
      await tester.pumpAndSettle();

      expect(find.textContaining("Create an admin account first"), findsOneWidget);
    });

    testWidgets("Cancel makes nothing", (WidgetTester tester) async {
      await tester.pumpWidget(launcher(kind: ShareKind.download, path: "/readme.txt"));
      await openDialog(tester);
      await tester.tap(find.text("Cancel"));
      await tester.pumpAndSettle();

      expect(find.text("Share a link"), findsNothing);
      expect(await shares.list(), isEmpty);
    });
  });
}
