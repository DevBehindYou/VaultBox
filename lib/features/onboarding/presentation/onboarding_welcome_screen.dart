import "package:flutter/material.dart";
import "package:go_router/go_router.dart";

import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";

/// First of three onboarding screens: Welcome → Choose storage → Admin
/// account → Ready.
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
              const AuroraStatusChip(label: "Step 1 of 3", status: AuroraStatus.idle),
              const SizedBox(height: AuroraSpacing.lg),
              Text(
                "Turn this phone into your\npersonal storage server.",
                style: AuroraTypography.displayXlMobile,
              ),
              const SizedBox(height: AuroraSpacing.md),
              Text(
                "Keep your files here and browse them in the app. Start the server "
                "whenever a laptop, tablet or another phone on your Wi-Fi should reach them.",
                style: AuroraTypography.bodyLg.copyWith(color: context.inkSecondary),
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
