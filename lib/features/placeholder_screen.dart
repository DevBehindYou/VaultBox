import "package:flutter/material.dart";

import "../core/design/aurora_colors.dart";
import "../core/design/aurora_spacing.dart";
import "../core/design/aurora_typography.dart";
import "../core/design/aurora_widgets.dart";

/// Honest placeholder for a destination whose feature phase hasn't been built
/// yet. Kickoff §77 forbids fake-functional UI: this screen states plainly
/// what's coming and when, and offers no controls that appear to work.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    required this.title,
    required this.phase,
    required this.description,
    super.key,
  });

  final String title;
  final String phase;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: AuroraTypography.headlineLg),
              const SizedBox(height: AuroraSpacing.md),
              AuroraCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    AuroraStatusChip(label: phase, status: AuroraStatus.idle),
                    const SizedBox(height: AuroraSpacing.sm),
                    Text(
                      description,
                      style: AuroraTypography.bodyMd.copyWith(
                        color: AuroraColors.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
