import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:go_router/go_router.dart";

import "app/app_providers.dart";
import "app/app_state.dart";
import "app/providers.dart";
import "app/router.dart";
import "core/design/aurora_context.dart";
import "core/design/aurora_theme.dart";
import "core/logging/app_logger.dart";
import "domain/entities/app_preferences.dart";
import "server/server_main.dart";

/// The service's headless engine looks `serverMain` up BY NAME
/// (`ServerForegroundService`), and nothing in the UI calls it — without a
/// reference from here the library would not be linked into the app at all.
// ignore: unused_element
const Future<void> Function() _serverEntrypoint = serverMain;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();
  final AppDependencies deps = AppDependencies.build();
  // Built once, outside the widget tree, like every other Riverpod-cached
  // singleton this rewrite touched — a GoRouter must never be rebuilt on a
  // theme change, or the whole navigation stack resets.
  final GoRouter router = buildRouter();
  runApp(
    MultiRepositoryProvider(
      providers: buildRepositoryProviders(deps),
      child: MultiBlocProvider(
        providers: buildAppBlocProviders(),
        child: VaultBoxApp(router: router),
      ),
    ),
  );
}

class VaultBoxApp extends StatelessWidget {
  const VaultBoxApp({required this.router, super.key});

  final GoRouter router;

  @override
  Widget build(BuildContext context) {
    // Until the saved choices load (a blink), the defaults apply.
    final AppPreferences prefs = context.watch<PreferencesCubit>().state;
    final AuroraStyle style = AuroraStyle(handwrittenHeadlines: prefs.handwrittenHeadlines, gradients: prefs.gradients);
    final VisualDensity density = switch (prefs.density) {
      UiDensity.compact => VisualDensity.compact,
      UiDensity.comfortable => VisualDensity.standard,
      UiDensity.expanded => const VisualDensity(horizontal: 1, vertical: 1),
    };

    return MaterialApp.router(
      title: "Atomic Carton",
      debugShowCheckedModeBanner: false,
      theme: AuroraTheme.light(style: style, density: density),
      darkTheme: AuroraTheme.dark(style: style, density: density),
      themeMode: switch (prefs.theme) {
        ThemePreference.system => ThemeMode.system,
        ThemePreference.light => ThemeMode.light,
        ThemePreference.dark => ThemeMode.dark,
      },
      routerConfig: router,
    );
  }
}
