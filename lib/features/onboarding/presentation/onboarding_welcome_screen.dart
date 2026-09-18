import "package:flutter/material.dart";
import "package:go_router/go_router.dart";

import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";

/// First of three onboarding screens (doc §7 "Onboarding": Welcome → Choose
/// Storage → [Admin/Security/Server, Phase 3] → Ready). Steps are combined
/// where the doc allows it (§7) — Phase 1 has no server or auth yet, so this
/// build skips straight from storage choice to Ready rather than showing
/// setup steps for features that don't exist.
class OnboardingWelcomeScreen extends StatelessWidget {
  const OnboardingWelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const AuroraStatusChip(label: "Step 1 of 2", status: AuroraStatus.idle),
              const SizedBox(height: AuroraSpacing.lg),
              Text(
                "Turn this phone into your\npersonal storage server.",
                style: AuroraTypography.displayXlMobile,
              ),
              const SizedBox(height: AuroraSpacing.md),
              Text(
                "Store files here and browse them right from the app. "
                "Network access from other devices arrives in a later update.",
                style: AuroraTypography.bodyLg.copyWith(color: AuroraColors.inkSecondary),
              ),
              const Spacer(),
              AuroraPrimaryButton(
                label: "Set up this phone",
                icon: Icons.arrow_forward,
                onPressed: () => context.push("/onboarding/storage"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
