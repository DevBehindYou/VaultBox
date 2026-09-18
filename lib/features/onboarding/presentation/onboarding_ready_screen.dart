import "package:flutter/material.dart";
import "package:go_router/go_router.dart";

import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";

class OnboardingReadyScreen extends StatelessWidget {
  const OnboardingReadyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Spacer(),
              const Icon(Icons.check_circle, size: 48, color: AuroraColors.statusSuccess),
              const SizedBox(height: AuroraSpacing.md),
              Text("You're set up.", style: AuroraTypography.displayXlMobile),
              const SizedBox(height: AuroraSpacing.sm),
              Text(
                "Your storage is ready. Browse, add and organize files from the "
                "Files tab any time.",
                style: AuroraTypography.bodyLg.copyWith(color: AuroraColors.inkSecondary),
              ),
              const Spacer(),
              AuroraPrimaryButton(
                label: "Go to VaultBox",
                // go(), not push() — this replaces the onboarding stack so the
                // back button can never re-enter it (same principle as doc
                // §7.2's login-redirect rule: don't leave a dead-end screen
                // reachable by Back once its job is done).
                onPressed: () => context.go("/home"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
