import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:vaultbox/app/app_state.dart";
import "package:vaultbox/app/shell_scaffold.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/domain/repositories/server_host.dart";

import "../helpers/fake_server_host.dart";

/// The dock's sliding lens: it follows the four dock tabs and must never be
/// pushed off the dock by Settings, the fifth branch that has no dock slot.
void main() {
  late GoRouter router;

  Future<void> show(WidgetTester tester) async {
    GoRoute page(String path) => GoRoute(
      path: path,
      builder: (BuildContext c, GoRouterState s) => Scaffold(body: Text("route:$path")),
    );
    router = GoRouter(
      initialLocation: "/home",
      routes: <RouteBase>[
        StatefulShellRoute.indexedStack(
          builder: (BuildContext c, GoRouterState s, StatefulNavigationShell shell) => ShellScaffold(shell: shell),
          branches: <StatefulShellBranch>[
            for (final String path in <String>["/home", "/files", "/server", "/activity", "/settings"])
              StatefulShellBranch(routes: <RouteBase>[page(path)]),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: <RepositoryProvider<dynamic>>[RepositoryProvider<ServerHost>.value(value: FakeServerHost())],
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

  double lensX(WidgetTester tester) =>
      (tester.widget<AnimatedAlign>(find.byType(AnimatedAlign)).alignment as Alignment).x;

  double lensOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(find.descendant(of: find.byType(AnimatedAlign), matching: find.byType(AnimatedOpacity)))
      .opacity;

  testWidgets("the lens sits under the selected dock tab", (WidgetTester tester) async {
    await show(tester);
    expect(lensX(tester), -1);
    expect(lensOpacity(tester), 1);

    await tester.tap(find.text("Activity"));
    await tester.pumpAndSettle();
    expect(lensX(tester), 1);
    expect(lensOpacity(tester), 1);
  });

  testWidgets("Settings keeps the lens on the dock and fades it out", (WidgetTester tester) async {
    await show(tester);
    await tester.tap(find.text("Server"));
    await tester.pumpAndSettle();
    final double serverX = lensX(tester);

    router.go("/settings");
    await tester.pumpAndSettle();

    expect(find.text("route:/settings"), findsOneWidget);
    expect(lensX(tester), serverX, reason: "stays over the last dock tab instead of sliding off the edge");
    expect(lensX(tester), inInclusiveRange(-1, 1));
    expect(lensOpacity(tester), 0);

    await tester.tap(find.text("Home"));
    await tester.pumpAndSettle();
    expect(lensX(tester), -1);
    expect(lensOpacity(tester), 1);
  });
}
