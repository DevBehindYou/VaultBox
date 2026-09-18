import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "app/router.dart";
import "core/design/aurora_theme.dart";
import "core/logging/app_logger.dart";
import "server/server_main.dart";

/// The service's headless engine looks `serverMain` up BY NAME
/// (`ServerForegroundService`), and nothing in the UI calls it — without a
/// reference from here the library would not be linked into the app at all.
// ignore: unused_element
const Future<void> Function() _serverEntrypoint = serverMain;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();
  runApp(const ProviderScope(child: VaultBoxApp()));
}

class VaultBoxApp extends ConsumerWidget {
  const VaultBoxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GoRouter router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: "VaultBox",
      debugShowCheckedModeBanner: false,
      theme: AuroraTheme.light(),
      darkTheme: AuroraTheme.dark(),
      // System theme by default (doc §68 "Sensible defaults").
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
