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
      // Found on a real phone at the OS's max accessibility text size (2.0x):
      // the dock and header have fixed heights (kickoff's Aurora Glass dock,
      // the 60px AppHeader bar) that a full unclamped scale overflows —
      // "BOTTOM OVERFLOWED BY 34 PIXELS" on the dock, a clipped header
      // subtitle, a clipped button label. 1.3x held up cleanly everywhere
      // checked (Home, the onboarding banner, the dock); this clamps rather
      // than redesigning every fixed-height widget in the app for unlimited
      // scale — still real enlargement for low vision, just not unbounded.
      builder: (BuildContext context, Widget? child) {
        final TextScaler clamped = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: clamped),
          child: child!,
        );
      },
    );
  }
}
