import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:go_router/go_router.dart";

import "../core/design/aurora_components.dart";
import "../core/design/aurora_context.dart";
import "../core/design/aurora_spacing.dart";
import "../core/design/aurora_typography.dart";
import "../core/design/aurora_widgets.dart";
import "../core/state/resource.dart";
import "../core/utils/byte_format.dart";
import "../domain/entities/account.dart";
import "../domain/entities/storage_root.dart";
import "../features/activity/presentation/activity_screen.dart";
import "../features/files/presentation/files_screen.dart";
import "../features/files/viewmodel/files_view_model.dart";
import "../features/home/presentation/home_screen.dart";
import "../platform/adapters/volume_stats_source.dart";
import "../features/onboarding/presentation/admin_setup_screen.dart";
import "../features/onboarding/presentation/onboarding_ready_screen.dart";
import "../features/onboarding/presentation/onboarding_storage_screen.dart";
import "../features/onboarding/presentation/onboarding_welcome_screen.dart";
import "../features/settings/presentation/appearance_screen.dart";
import "../features/settings/presentation/diagnostics_screen.dart";
import "../features/settings/presentation/protocols_screen.dart";
import "../features/settings/presentation/security_screen.dart";
import "../features/settings/presentation/settings_screen.dart";
import "../features/settings/presentation/storage_screen.dart";
import "../features/share/presentation/add_person_screen.dart";
import "../features/share/presentation/person_screen.dart";
import "../features/share/presentation/share_screen.dart";
import "app_state.dart";
import "shell_scaffold.dart";

/// Route table. Exactly five permanent destinations (doc §8 / kickoff §6);
/// Vault, Users, Diagnostics, WebDAV, API, Storage and Logs are reached from
/// within these, never as their own tab.
///
/// `StatefulShellRoute.indexedStack` gives each tab its own Navigator, so a
/// deep Files stack survives a trip to Settings and back (KB vol2 §7.1).
GoRouter buildRouter() {
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
        path: "/onboarding/admin",
        builder: (BuildContext context, GoRouterState state) => AdminSetupScreen(
          stepLabel: "Step 3 of 3",
          skipLabel: "Skip for now",
          onSkip: (BuildContext context) => context.go("/onboarding/ready"),
          onDone: (BuildContext context) => context.go("/onboarding/ready"),
        ),
      ),
      // Reached from Home when no admin exists yet (outside the shell: no dock).
      GoRoute(
        path: "/admin/new",
        builder: (BuildContext context, GoRouterState state) =>
            AdminSetupScreen(onDone: (BuildContext context) => context.go("/home")),
      ),
      // People (outside the shell: no dock while adding or editing someone).
      GoRoute(
        path: "/people/new",
        builder: (BuildContext context, GoRouterState state) => AddPersonScreen(
          onDone: (BuildContext context, Account account) => context.pushReplacement("/people/${account.id}"),
        ),
      ),
      GoRoute(
        path: "/people/:id",
        builder: (BuildContext context, GoRouterState state) => PersonScreen(
          accountId: state.pathParameters["id"]!,
          onRemoved: (BuildContext context) => context.pop(),
        ),
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
                builder: (BuildContext context, GoRouterState state) => const ShareScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: "/activity",
                builder: (BuildContext context, GoRouterState state) => const ActivityScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: "/settings",
                builder: (BuildContext context, GoRouterState state) => const SettingsScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: "protocols",
                    builder: (BuildContext context, GoRouterState state) => const ProtocolsScreen(),
                  ),
                  GoRoute(
                    path: "security",
                    builder: (BuildContext context, GoRouterState state) => const SecurityScreen(),
                  ),
                  GoRoute(
                    path: "storage",
                    builder: (BuildContext context, GoRouterState state) => const StorageScreen(),
                  ),
                  GoRoute(
                    path: "appearance",
                    builder: (BuildContext context, GoRouterState state) => const AppearanceScreen(),
                  ),
                  GoRoute(
                    path: "diagnostics",
                    builder: (BuildContext context, GoRouterState state) => const DiagnosticsScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

/// Resolves which root the Files tab shows: the person's last choice from the
/// switcher, else the default root, else the first. With more than one root a
/// chip row above the file list switches between them; with a single root it
/// stays out of the way. Shows a clear empty state when no storage is
/// configured yet, rather than crashing on a missing root.
class _FilesEntryPoint extends StatefulWidget {
  const _FilesEntryPoint();

  @override
  State<_FilesEntryPoint> createState() => _FilesEntryPointState();
}

class _FilesEntryPointState extends State<_FilesEntryPoint> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final Resource<List<StorageRoot>> roots = context.watch<StorageRootsCubit>().state;
    final Map<String, VolumeStats> stats =
        context.watch<RootStatsCubit>().state.value ?? const <String, VolumeStats>{};

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
          (StorageRoot r) => r.id == _selectedId,
          orElse: () => list.firstWhere(
            (StorageRoot r) => r.isDefault,
            orElse: () => list.first,
          ),
        );
        // Keyed by root so switching roots gives a fresh screen (own paging,
        // selection and sort state) instead of reusing the previous one.
        final Widget files = FilesScreen(
          key: ValueKey<String>(root.id),
          directory: rootRef(root),
        );
        if (list.length < 2) return files;

        return Column(
          children: <Widget>[
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AuroraSpacing.marginCompact,
                  AuroraSpacing.sm,
                  AuroraSpacing.marginCompact,
                  0,
                ),
                child: Row(
                  children: <Widget>[
                    Text("Volumes & Mounts", style: AuroraTypography.headlineSm),
                    const Spacer(),
                    Text(
                      "${list.length} MOUNTED",
                      style: AuroraTypography.labelMonoMd.copyWith(color: context.inkTertiary),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AuroraSpacing.sm),
            SizedBox(
              height: 152,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AuroraSpacing.marginCompact),
                itemCount: list.length,
                separatorBuilder: (BuildContext context, int index) =>
                    const SizedBox(width: AuroraSpacing.sm),
                itemBuilder: (BuildContext context, int index) {
                  final StorageRoot candidate = list[index];
                  return _VolumeCard(
                    root: candidate,
                    stats: stats[candidate.id],
                    selected: candidate.id == root.id,
                    onTap: () => setState(() => _selectedId = candidate.id),
                  );
                },
              ),
            ),
            const SizedBox(height: AuroraSpacing.sm),
            Expanded(child: files),
          ],
        );
      },
    );
  }
}

/// One card in the Files tab's volume row: kind, name, and a used/free meter
/// when the native side has reported [stats] (see `RootStatsCubit`).
class _VolumeCard extends StatelessWidget {
  const _VolumeCard({
    required this.root,
    required this.stats,
    required this.selected,
    required this.onTap,
  });

  final StorageRoot root;
  final VolumeStats? stats;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final VolumeStats? measured = stats;
    final int? used = measured == null ? null : measured.totalBytes - measured.freeBytes;

    return SizedBox(
      width: 176,
      child: AuroraCard(
        onTap: onTap,
        borderColor: selected ? context.scheme.primary : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AuroraColors.auroraLavender.withValues(alpha: 0.14),
                    borderRadius: AuroraRadii.standardAll,
                  ),
                  child: Icon(
                    root.isRemovable ? Icons.sd_card_outlined : Icons.smartphone_outlined,
                    size: 18,
                    color: AuroraColors.auroraLavender,
                  ),
                ),
                const Spacer(),
                if (root.isDefault)
                  const AuroraStatusChip(label: "Default", status: AuroraStatus.idle)
                else if (!root.isAvailable)
                  const AuroraStatusChip(label: "Offline", status: AuroraStatus.warning),
              ],
            ),
            const SizedBox(height: AuroraSpacing.sm),
            Text(
              root.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AuroraTypography.bodyLg.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              !root.isAvailable
                  ? "Not reachable"
                  : measured == null
                  ? "Size unknown"
                  : "${ByteFormat.format(used!)} / ${ByteFormat.format(measured.totalBytes)}",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AuroraTypography.labelMonoMd.copyWith(color: context.inkSecondary),
            ),
            const Spacer(),
            if (measured != null && root.isAvailable)
              AuroraStorageMeter(
                format: ByteFormat.format,
                showLegend: false,
                segments: <MeterSegment>[
                  MeterSegment(label: "Used", bytes: used!, color: AuroraColors.auroraLavender),
                  MeterSegment(
                    label: "Free",
                    bytes: measured.freeBytes,
                    color: context.statusSuccessBorder,
                  ),
                ],
              ),
          ],
        ),
      ),
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
                style: AuroraTypography.bodyMd.copyWith(color: context.inkSecondary),
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
