import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/app_state.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/data/repositories/in_memory_activity_repository.dart";
import "package:vaultbox/domain/entities/activity.dart";
import "package:vaultbox/domain/repositories/activity_repository.dart";
import "package:vaultbox/domain/repositories/clock.dart";
import "package:vaultbox/features/activity/presentation/activity_screen.dart";

import "../helpers/fake_clock.dart";

void main() {
  late FakeClock clock;
  late InMemoryActivityRepository repo;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 9, 20, 12));
    repo = InMemoryActivityRepository();
  });

  Widget app() => MultiRepositoryProvider(
    providers: <RepositoryProvider<dynamic>>[
      RepositoryProvider<ActivityRepository>.value(value: repo),
      RepositoryProvider<Clock>.value(value: clock),
    ],
    child: MultiBlocProvider(
      providers: <BlocProvider<dynamic>>[
        BlocProvider<ActivityEventsCubit>(create: (BuildContext context) => ActivityEventsCubit(context.read<ActivityRepository>())),
        BlocProvider<ActivityTransfersCubit>(
          create: (BuildContext context) => ActivityTransfersCubit(context.read<ActivityRepository>()),
        ),
        BlocProvider<ActivityClientsCubit>(
          create: (BuildContext context) => ActivityClientsCubit(context.read<ActivityRepository>(), context.read<Clock>()),
        ),
      ],
      child: MaterialApp(theme: AuroraTheme.light(), home: const ActivityScreen()),
    ),
  );

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String section) async {
    await tester.tap(find.text(section));
    await tester.pumpAndSettle();
  }

  Future<void> addTransfer(
    String id, {
    String name = "movie.mp4",
    TransferDirection direction = TransferDirection.download,
    TransferState state = TransferState.running,
    int bytes = 0,
    int? total,
    Duration started = const Duration(minutes: 2),
    Duration idle = Duration.zero,
    AccessVia via = AccessVia.web,
    String actor = "admin",
  }) async {
    await repo.beginTransfer(
      TransferRecord(
        id: id,
        direction: direction,
        via: via,
        actor: actor,
        name: name,
        startedAt: clock.now().subtract(started),
        updatedAt: clock.now().subtract(idle),
        bytes: bytes,
        totalBytes: total,
        state: state,
      ),
    );
  }

  group("Transfers", () {
    testWidgets("is the first section, and says what will appear when empty", (WidgetTester tester) async {
      await show(tester);

      expect(find.text("Transfers"), findsOneWidget);
      expect(find.textContaining("Nothing has moved yet"), findsOneWidget);
    });

    testWidgets("a running download shows its progress and who it goes to", (WidgetTester tester) async {
      await addTransfer("t1", bytes: 1024 * 1024, total: 4 * 1024 * 1024);
      await show(tester);

      expect(find.text("movie.mp4"), findsOneWidget);
      expect(find.text("Sending"), findsOneWidget);
      expect(find.text("To admin · Browser · 2 minutes ago"), findsOneWidget);
      expect(find.text("1.0 MB of 4.0 MB"), findsOneWidget);
      final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, 0.25);
    });

    testWidgets("a running upload says Receiving and where from", (WidgetTester tester) async {
      await addTransfer("t1", name: "scan.pdf", direction: TransferDirection.upload, via: AccessVia.link, actor: "Link");
      await show(tester);

      expect(find.text("Receiving"), findsOneWidget);
      expect(find.text("From Link · Link · 2 minutes ago"), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing, reason: "no known size, so no bar");
    });

    testWidgets("finished ones say how they ended, with no progress bar", (WidgetTester tester) async {
      await addTransfer("done", name: "a.txt", state: TransferState.completed, bytes: 2048, total: 2048);
      await addTransfer("bad", name: "b.txt", state: TransferState.failed, bytes: 10, total: 100);
      await addTransfer("gone", name: "c.txt", state: TransferState.interrupted, bytes: 50, total: 100);
      await show(tester);

      expect(find.text("Done"), findsOneWidget);
      expect(find.text("Failed"), findsOneWidget);
      expect(find.text("Stopped"), findsOneWidget);
      expect(find.text("2.0 KB"), findsOneWidget);
      expect(find.text("50 B of 100 B"), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets("a running transfer that went quiet is Stalled, not still moving", (WidgetTester tester) async {
      await addTransfer("t1", bytes: 10, total: 100, idle: const Duration(minutes: 30), started: const Duration(hours: 1));
      await show(tester);

      expect(find.text("Stalled"), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets("running ones are listed above finished ones", (WidgetTester tester) async {
      await addTransfer("done", name: "finished.txt", state: TransferState.completed, started: const Duration(minutes: 1));
      await addTransfer("run", name: "moving.txt", started: const Duration(minutes: 30));
      await show(tester);

      expect(
        tester.getTopLeft(find.text("moving.txt")).dy,
        lessThan(tester.getTopLeft(find.text("finished.txt")).dy),
      );
    });

    testWidgets("refreshes on its own while open", (WidgetTester tester) async {
      await show(tester);
      expect(find.text("late.bin"), findsNothing);

      await addTransfer("t1", name: "late.bin");
      await tester.pump(activityPollInterval + const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(find.text("late.bin"), findsOneWidget);
    });
  });

  group("Clients", () {
    ClientRecord client(String actor, String address, Duration lastSeen, {AccessVia via = AccessVia.web}) => ClientRecord(
      actor: actor,
      address: address,
      via: via,
      firstSeenAt: clock.now().subtract(const Duration(hours: 3)),
      lastSeenAt: clock.now().subtract(lastSeen),
    );

    testWidgets("says so when nobody has connected", (WidgetTester tester) async {
      await show(tester);
      await open(tester, "Clients");

      expect(find.text("Nobody has connected in the last day."), findsOneWidget);
    });

    testWidgets("a recently seen client is Connected, an older one says when it was last here", (WidgetTester tester) async {
      await repo.touchClient(client("bob", "192.168.1.20", const Duration(minutes: 1)));
      await repo.touchClient(client("ann", "192.168.1.21", const Duration(hours: 2), via: AccessVia.webdav));
      await show(tester);
      await open(tester, "Clients");

      expect(find.text("bob"), findsOneWidget);
      expect(find.text("Browser · 192.168.1.20"), findsOneWidget);
      expect(find.text("Connected"), findsOneWidget);
      expect(find.text("ann"), findsOneWidget);
      expect(find.text("WebDAV · 192.168.1.21"), findsOneWidget);
      expect(find.text("2 hours ago"), findsOneWidget);
      expect(find.text("Since 3 hours ago"), findsNWidgets(2));
    });

    testWidgets("a client not seen for a day is not listed", (WidgetTester tester) async {
      await repo.touchClient(client("old", "10.0.0.9", const Duration(days: 2)));
      await show(tester);
      await open(tester, "Clients");

      expect(find.text("old"), findsNothing);
    });
  });

  group("Events", () {
    testWidgets("says so when nothing happened", (WidgetTester tester) async {
      await show(tester);
      await open(tester, "Events");

      expect(find.textContaining("Nothing has happened yet"), findsOneWidget);
    });

    testWidgets("lists what happened, newest first, with where it came from", (WidgetTester tester) async {
      await repo.addEvent(
        ActivityEvent(
          id: "1",
          at: clock.now().subtract(const Duration(hours: 1)),
          kind: ActivityKind.signedIn,
          message: "admin signed in.",
          address: "192.168.1.10",
        ),
      );
      await repo.addEvent(
        ActivityEvent(
          id: "2",
          at: clock.now().subtract(const Duration(minutes: 3)),
          kind: ActivityKind.signInRefused,
          severity: ActivitySeverity.warning,
          message: "A sign-in was refused: wrong name or password.",
          address: "192.168.1.99",
        ),
      );
      await repo.addEvent(
        ActivityEvent(
          id: "3",
          at: clock.now().subtract(const Duration(days: 2)),
          kind: ActivityKind.serverStarted,
          message: "The server started.",
        ),
      );
      await show(tester);
      await open(tester, "Events");

      expect(find.text("admin signed in."), findsOneWidget);
      expect(find.text("an hour ago · 192.168.1.10"), findsOneWidget);
      expect(find.text("A sign-in was refused: wrong name or password."), findsOneWidget);
      expect(find.text("3 minutes ago · 192.168.1.99"), findsOneWidget);
      expect(find.text("2 days ago"), findsOneWidget, reason: "an event with no address shows only the time");
      expect(
        tester.getTopLeft(find.text("A sign-in was refused: wrong name or password.")).dy,
        lessThan(tester.getTopLeft(find.text("admin signed in.")).dy),
      );
    });
  });

  group("Clear the history", () {
    Future<void> seed() async {
      await addTransfer("t1", name: "keep-me.bin", state: TransferState.completed, bytes: 1, total: 1);
      await repo.addEvent(
        ActivityEvent(id: "e", at: clock.now(), kind: ActivityKind.signedIn, message: "admin signed in."),
      );
    }

    testWidgets("asks first; Keep changes nothing", (WidgetTester tester) async {
      await seed();
      await show(tester);

      await tester.tap(find.byTooltip("Clear the history"));
      await tester.pumpAndSettle();
      expect(find.text("Clear the history?"), findsOneWidget);
      await tester.tap(find.text("Keep"));
      await tester.pumpAndSettle();

      expect(find.text("keep-me.bin"), findsOneWidget);
      expect(await repo.recentTransfers(), hasLength(1));
    });

    testWidgets("Clear empties every list at once", (WidgetTester tester) async {
      await seed();
      await show(tester);

      await tester.tap(find.byTooltip("Clear the history"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Clear"));
      await tester.pumpAndSettle();

      expect(find.text("keep-me.bin"), findsNothing);
      expect(find.textContaining("Nothing has moved yet"), findsOneWidget);
      expect(await repo.recentTransfers(), isEmpty);
      expect(await repo.recentEvents(), isEmpty);
    });
  });
}
