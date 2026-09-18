import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/errors/app_failure.dart";
import "../onboarding_actions.dart";

/// Storage-choice step. See `onboarding_actions.dart` for why "this phone's
/// app storage" is the only live option in this delivery, and why the SD
/// card / custom-folder option below is shown but disabled rather than
/// hidden — kickoff §77 prefers a labelled "coming later" over silently
/// removing something the design calls for.
class OnboardingStorageScreen extends ConsumerStatefulWidget {
  const OnboardingStorageScreen({super.key});

  @override
  ConsumerState<OnboardingStorageScreen> createState() => _OnboardingStorageScreenState();
}

class _OnboardingStorageScreenState extends ConsumerState<OnboardingStorageScreen> {
  bool _isWorking = false;
  AppFailure? _failure;

  Future<void> _useAppStorage() async {
    setState(() {
      _isWorking = true;
      _failure = null;
    });
    try {
      await addAppStorageRoot(ref);
      if (!mounted) return;
      unawaited(context.push("/onboarding/admin"));
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Future<void> _useCustomFolder() async {
    setState(() {
      _isWorking = true;
      _failure = null;
    });
    try {
      final String? rootId = await addSafStorageRoot(ref);
      if (!mounted) return;
      // null = the person cancelled the system picker: stay on this screen.
      if (rootId != null) unawaited(context.push("/onboarding/admin"));
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: const Text("Choose storage")),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const AuroraStatusChip(label: "Step 2 of 3", status: AuroraStatus.idle),
              const SizedBox(height: AuroraSpacing.md),
              Text("Where should VaultBox keep your files?", style: AuroraTypography.headlineMd),
              const SizedBox(height: AuroraSpacing.lg),
              if (_failure != null) ...<Widget>[
                AuroraInlineBanner(
                  message: _failure!.message,
                  status: AuroraStatus.danger,
                  technicalDetail: _failure!.debugDetail,
                  onDismiss: () => setState(() => _failure = null),
                ),
                const SizedBox(height: AuroraSpacing.md),
              ],
              AuroraCard(
                onTap: _isWorking ? null : _useAppStorage,
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.smartphone_outlined, color: AuroraColors.auroraLavender),
                    const SizedBox(width: AuroraSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text("This phone", style: AuroraTypography.bodyLg),
                          Text(
                            "VaultBox's own private storage. Works immediately.",
                            style: AuroraTypography.bodySm
                                .copyWith(color: AuroraColors.inkSecondary),
                          ),
                        ],
                      ),
                    ),
                    if (_isWorking)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.chevron_right),
                  ],
                ),
              ),
              const SizedBox(height: AuroraSpacing.sm),
              AuroraCard(
                onTap: _isWorking ? null : _useCustomFolder,
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.sd_card_outlined, color: AuroraColors.auroraLavender),
                    const SizedBox(width: AuroraSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text("SD card or custom folder", style: AuroraTypography.bodyLg),
                          Text(
                            "Pick any folder on this phone or an SD card. "
                            "You'll be asked to grant VaultBox access to it.",
                            style: AuroraTypography.bodySm
                                .copyWith(color: AuroraColors.inkSecondary),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right),
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
