import "dart:async";

import "package:flutter/material.dart";
import "package:go_router/go_router.dart";

import "../../../core/app_info.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";

/// Settings. Only what exists is listed: the other groups (network, security,
/// appearance…) arrive with the phases that build them, and are not faked here.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          child: ListView(
            children: <Widget>[
              Text("Settings", style: AuroraTypography.headlineLg),
              const SizedBox(height: AuroraSpacing.md),
              _SettingsRow(
                icon: Icons.health_and_safety_outlined,
                title: "Diagnostics",
                subtitle: "Check that everything works, and copy a support bundle.",
                onTap: () => unawaited(context.push("/settings/diagnostics")),
              ),
              const SizedBox(height: AuroraSpacing.sm),
              _SettingsRow(
                icon: Icons.info_outline,
                title: "About VaultBox",
                subtitle: "Version $appVersion and open-source licences.",
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: "VaultBox",
                  applicationVersion: appVersion,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AuroraCard(
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Icon(icon),
          const SizedBox(width: AuroraSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: AuroraTypography.headlineSm),
                const SizedBox(height: AuroraSpacing.xs),
                Text(subtitle, style: AuroraTypography.bodySm.copyWith(color: AuroraColors.inkSecondary)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}
