import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "../core/design/aurora_context.dart";
import "../core/design/aurora_spacing.dart";
import "../domain/entities/server_state.dart";
import "providers.dart";

/// The bar across the top of every tab: the mark and name, which tab this is,
/// whether the server is up, and shortcuts to the connection settings and to
/// security (the round button).
class AppHeader extends ConsumerWidget {
  const AppHeader({required this.subtitle, super.key});

  final String subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerState server = ref.watch(serverStateProvider).value ?? const ServerState.stopped();

    return Container(
      height: 60,
      color: context.scheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: AuroraSpacing.marginCompact),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: AuroraRadii.standardAll,
            child: Image.asset("assets/images/vaultbox_mark.png", width: 32, height: 32, fit: BoxFit.cover),
          ),
          const SizedBox(width: AuroraSpacing.sm),
          Flexible(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text("VaultBox", style: context.brand(22), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(subtitle, style: context.mono(size: 10, color: context.inkTertiary), maxLines: 1),
              ],
            ),
          ),
          const Spacer(),
          ServerStatusPill(server: server),
          IconButton(
            tooltip: "Server and network settings",
            icon: Icon(Icons.tune, color: context.inkSecondary),
            onPressed: () => context.go("/settings/protocols"),
          ),
          Semantics(
            button: true,
            label: "Security and sessions",
            child: InkWell(
              onTap: () => context.go("/settings/security"),
              customBorder: const CircleBorder(),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(shape: BoxShape.circle, color: context.scheme.primary),
                child: Icon(Icons.person_outline, size: 20, color: context.scheme.onPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Server Live" / "Server Off" — the state in words and a dot.
class ServerStatusPill extends StatelessWidget {
  const ServerStatusPill({required this.server, super.key});

  final ServerState server;

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (server.run) {
      ServerRunState.running => ("Server Live", context.statusSuccess),
      ServerRunState.starting => ("Starting…", context.statusWarning),
      ServerRunState.failed => ("Server Error", context.statusDanger),
      ServerRunState.stopped => ("Server Off", context.inkTertiary),
    };
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: AuroraRadii.pillAll,
        border: context.isDarkTheme ? Border.all(color: context.borderDefault) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 6),
          Text(label, style: context.mono(color: color, weight: FontWeight.w600)),
        ],
      ),
    );
  }
}
