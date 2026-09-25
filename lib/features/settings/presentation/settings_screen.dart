import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:go_router/go_router.dart";

import "../../../app/app_state.dart";
import "../../../core/app_info.dart";
import "../../../core/design/aurora_components.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../domain/entities/server_config.dart";
import "../../../domain/entities/storage_root.dart";

/// Settings: everything you can configure or check, in a few plain groups. Only
/// what exists is listed — a setting that isn't built yet is not shown, rather
/// than shown and broken.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ServerConfig? config = context.watch<ServerConfigCubit>().state.value;
    final List<StorageRoot>? roots = context.watch<StorageRootsCubit>().state.value;

    final String protocols = config == null
        ? "HTTPS, WebDAV, ports and network access"
        : <String>[
            if (config.httpsEnabled) "HTTPS ${config.port}",
            if (config.httpEnabled) "HTTP ${config.httpPort}",
            "WebDAV",
          ].join(" · ");
    final String storage = roots == null
        ? "Where your files live"
        : roots.isEmpty
        ? "Nothing added yet"
        : "${roots.length} ${roots.length == 1 ? "location" : "locations"} served";

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AuroraSpacing.marginCompact,
          0,
          AuroraSpacing.marginCompact,
          AuroraSpacing.dockScrollClearance,
        ),
        children: <Widget>[
          const AuroraSectionHeader(title: "Server"),
          AuroraRowGroup(
            children: <Widget>[
              AuroraSettingRow(
                icon: Icons.hub_outlined,
                title: "Protocols & Network",
                subtitle: protocols,
                onTap: () => context.go("/server"),
              ),
              AuroraSettingRow(
                icon: Icons.shield_outlined,
                title: "Security & Sessions",
                subtitle: "Protection, who is signed in, and the certificate",
                onTap: () => context.go("/settings/security"),
              ),
            ],
          ),
          const AuroraSectionHeader(title: "Storage"),
          AuroraRowGroup(
            children: <Widget>[
              AuroraSettingRow(
                icon: Icons.storage_outlined,
                title: "Storage & Volumes",
                subtitle: storage,
                onTap: () => context.go("/settings/storage"),
              ),
            ],
          ),
          const AuroraSectionHeader(title: "Sharing"),
          AuroraRowGroup(
            children: <Widget>[
              AuroraSettingRow(
                icon: Icons.group_outlined,
                title: "People & links",
                subtitle: "Accounts, folder access, share and upload links",
                onTap: () => unawaited(context.push("/share")),
              ),
            ],
          ),
          const AuroraSectionHeader(title: "App"),
          AuroraRowGroup(
            children: <Widget>[
              AuroraSettingRow(
                icon: Icons.palette_outlined,
                title: "Appearance & Display",
                subtitle: "Light or dark, headings and spacing",
                onTap: () => context.go("/settings/appearance"),
              ),
            ],
          ),
          const AuroraSectionHeader(title: "System"),
          AuroraRowGroup(
            children: <Widget>[
              AuroraSettingRow(
                icon: Icons.health_and_safety_outlined,
                title: "Diagnostics",
                subtitle: "Check that everything works, and copy a support bundle",
                onTap: () => context.go("/settings/diagnostics"),
              ),
              AuroraSettingRow(
                icon: Icons.info_outline,
                title: "About Atomic Carton",
                subtitle: "Version $appVersion and open-source licences",
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: "Atomic Carton",
                  applicationVersion: appVersion,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: AuroraSpacing.lg),
            child: Text(
              "Atomic Carton keeps your files on this phone. Nothing is sent to any cloud.",
              style: context.caption,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
