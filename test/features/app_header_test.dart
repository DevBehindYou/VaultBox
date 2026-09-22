import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:vaultbox/app/app_header.dart";
import "package:vaultbox/app/app_state.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/domain/repositories/server_host.dart";

import "../helpers/fake_server_host.dart";

/// The bar at the top of every tab: who we are, which tab this is, whether the
/// server is up, and two shortcuts.
void main() {
  Future<void> show(WidgetTester tester, FakeServerHost host, {String subtitle = "Home"}) async {
    final GoRouter router = GoRouter(
      routes: <RouteBase>[
        GoRoute(path: "/", builder: (BuildContext c, GoRouterState s) => Scaffold(body: AppHeader(subtitle: subtitle))),
        GoRoute(path: "/settings/protocols", builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text("route:protocols"))),
        GoRoute(path: "/settings/security", builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text("route:security"))),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: <RepositoryProvider<dynamic>>[RepositoryProvider<ServerHost>.value(value: host)],
        child: MultiBlocProvider(
          providers: <BlocProvider<dynamic>>[
            BlocProvider<ServerStateCubit>(create: (BuildContext context) => ServerStateCubit(context.read<ServerHost>())),
          ],
          child: MaterialApp.router(theme: AuroraTheme.light(), routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets("names the app and the tab it is on", (WidgetTester tester) async {
    await show(tester, FakeServerHost(), subtitle: "Files");

    expect(find.text("VaultBox"), findsOneWidget);
    expect(find.text("Files"), findsOneWidget);
  });

  group("the server pill", () {
    testWidgets("off", (WidgetTester tester) async {
      await show(tester, FakeServerHost());
      expect(find.text("Server Off"), findsOneWidget);
    });

    testWidgets("live", (WidgetTester tester) async {
      await show(tester, FakeServerHost(const ServerState(run: ServerRunState.running, endpoint: "https://127.0.0.1:8443/")));
      expect(find.text("Server Live"), findsOneWidget);
    });

    testWidgets("starting", (WidgetTester tester) async {
      await show(tester, FakeServerHost(const ServerState(run: ServerRunState.starting)));
      expect(find.text("Starting…"), findsOneWidget);
    });

    testWidgets("failed", (WidgetTester tester) async {
      await show(tester, FakeServerHost(const ServerState(run: ServerRunState.failed, detail: "x")));
      expect(find.text("Server Error"), findsOneWidget);
    });

    testWidgets("follows the server as it starts and stops", (WidgetTester tester) async {
      final FakeServerHost host = FakeServerHost();
      await show(tester, host);
      expect(find.text("Server Off"), findsOneWidget);

      await host.start();
      await tester.pumpAndSettle();
      expect(find.text("Server Live"), findsOneWidget);

      await host.stop();
      await tester.pumpAndSettle();
      expect(find.text("Server Off"), findsOneWidget);
    });
  });

  group("shortcuts", () {
    testWidgets("the sliders button opens Protocols & Network", (WidgetTester tester) async {
      await show(tester, FakeServerHost());

      await tester.tap(find.byTooltip("Server and network settings"));
      await tester.pumpAndSettle();

      expect(find.text("route:protocols"), findsOneWidget);
    });

    testWidgets("the round button opens Security & Sessions, and says so to screen readers", (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await show(tester, FakeServerHost());
      expect(find.bySemanticsLabel("Security and sessions"), findsOneWidget);

      await tester.tap(find.byIcon(Icons.person_outline));
      await tester.pumpAndSettle();

      expect(find.text("route:security"), findsOneWidget);
      semantics.dispose();
    });
  });
}
