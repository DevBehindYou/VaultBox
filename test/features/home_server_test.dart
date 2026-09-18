import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/features/home/presentation/home_screen.dart";

import "../helpers/fake_server_host.dart";

/// Home's server card against a fake host: what the person sees for each state.
void main() {
  Widget harness(FakeServerHost host) {
    return ProviderScope(
      overrides: [
        serverHostProvider.overrideWithValue(host),
        storageRootRepositoryProvider.overrideWithValue(InMemoryStorageRootRepository()),
      ],
      child: MaterialApp(theme: AuroraTheme.light(), home: const HomeScreen()),
    );
  }

  testWidgets("start -> running shows the endpoint; stop returns to off", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost();
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
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    expect(find.text("Failed"), findsOneWidget);
    expect(find.text("Try again"), findsOneWidget);
    expect(find.text("Technical details"), findsOneWidget);
  });

  testWidgets("if asking the service to start throws, the person sees a message", (WidgetTester tester) async {
    final FakeServerHost host = FakeServerHost()..failStart = const UnexpectedFailure(debugDetail: "x");
    await tester.pumpWidget(harness(host));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Start server"));
    await tester.pumpAndSettle();

    expect(find.text("Something went wrong. Please try again."), findsOneWidget);
    expect(find.text("Server off"), findsOneWidget);
  });
}
