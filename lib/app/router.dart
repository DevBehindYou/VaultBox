import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "../core/design/aurora_colors.dart";
import "../core/design/aurora_spacing.dart";
import "../core/design/aurora_typography.dart";
import "../core/design/aurora_widgets.dart";
import "../domain/entities/storage_root.dart";
import "../features/files/presentation/files_screen.dart";
import "../features/files/viewmodel/files_view_model.dart";
import "../features/home/presentation/home_screen.dart";
import "../features/onboarding/presentation/onboarding_ready_screen.dart";
import "../features/onboarding/presentation/onboarding_storage_screen.dart";
import "../features/onboarding/presentation/onboarding_welcome_screen.dart";
import "../features/placeholder_screen.dart";
import "providers.dart";
import "shell_scaffold.dart";

/// Route table. Exactly five permanent destinations (doc §8 / kickoff §6);
/// Vault, Users, Diagnostics, WebDAV, API, Storage and Logs are reached from
/// within these, never as their own tab.
///
/// `StatefulShellRoute.indexedStack` gives each tab its own Navigator, so a
/// deep Files stack survives a trip to Settings and back (KB vol2 §7.1).
GoRouter buildRouter(Ref ref) {
  return GoRouter(
    initialLocation: "/home",
    routes: <RouteBase>[
      // Top-level, outside the shell — onboarding has no bottom nav dock and
      // no tab to return to mid-flow (KB vol2 §7.1: shell branches keep their
      // own stack, which is the wrong shape for a linear setup flow).
      GoRoute(
        path: "/onboarding/welcome",
        builder: (BuildContext context, GoRouterState state) =>
            const OnboardingWelcomeScreen(),
      ),
      GoRoute(
        path: "/onboarding/storage",
        builder: (BuildContext context, GoRouterState state) =>
            const OnboardingStorageScreen(),
      ),
      GoRoute(
        path: "/onboarding/ready",
        builder: (BuildContext context, GoRouterState state) => const OnboardingReadyScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (BuildContext context, GoRouterState state, StatefulNavigationShell shell) {
          return ShellScaffold(shell: shell);
        },
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: "/home",
                builder: (BuildContext context, GoRouterState state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: "/files",
                builder: (BuildContext context, GoRouterState state) =>
                    const _FilesEntryPoint(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: "/share",
                builder: (BuildContext context, GoRouterState state) =>
                    const PlaceholderScreen(
                      title: "Share",
                      phase: "Phase 5",
                      description:
                          "Shares, links, QR pairing and per-user access arrive once "
                          "the server and auth layers are in place.",
                    ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: "/activity",
                builder: (BuildContext context, GoRouterState state) =>
                    const PlaceholderScreen(
                      title: "Activity",
                      phase: "Phase 6",
                      description:
                          "Transfers, connected clients and the event log land "
                          "alongside the transfer engine and server.",
                    ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: "/settings",
                builder: (BuildContext context, GoRouterState state) =>
                    const PlaceholderScreen(
                      title: "Settings",
                      phase: "Phase 2+",
                      description:
                          "Storage, Server, Network, Security, Sharing, API, "
                          "Appearance and Diagnostics groups.",
                    ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

final Provider<GoRouter> routerProvider = Provider<GoRouter>(buildRouter);

/// Resolves which root the Files tab opens at. Until onboarding exists
/// (Phase 1 follow-up) this picks the default root, or the first available
/// one, and shows a clear empty state when no storage is configured yet —
/// rather than crashing on a missing root.
class _FilesEntryPoint extends ConsumerWidget {
  const _FilesEntryPoint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<StorageRoot>> roots = ref.watch(storageRootsProvider);

    return roots.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (Object error, StackTrace stack) => Scaffold(
        body: Center(child: Text("Couldn't load storage locations.\n$error")),
      ),
      data: (List<StorageRoot> list) {
        if (list.isEmpty) {
          return _NoStorageYet(onAddStorage: () => context.push("/onboarding/welcome"));
        }
        final StorageRoot root = list.firstWhere(
          (StorageRoot r) => r.isDefault,
          orElse: () => list.first,
        );
        return FilesScreen(directory: rootRef(root));
      },
    );
  }
}

class _NoStorageYet extends StatelessWidget {
  const _NoStorageYet({required this.onAddStorage});

  final VoidCallback onAddStorage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text("No storage yet", style: AuroraTypography.headlineLg),
              const SizedBox(height: AuroraSpacing.sm),
              Text(
                "Set up a storage location to start browsing and adding files.",
                style: AuroraTypography.bodyMd.copyWith(color: AuroraColors.inkSecondary),
              ),
              const SizedBox(height: AuroraSpacing.lg),
              AuroraPrimaryButton(
                label: "Set up storage",
                icon: Icons.arrow_forward,
                expand: false,
                onPressed: onAddStorage,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
