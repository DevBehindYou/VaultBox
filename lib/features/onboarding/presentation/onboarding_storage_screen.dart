import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:go_router/go_router.dart";

import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/errors/app_failure.dart";
import "../../../domain/repositories/account_repository.dart";
import "../onboarding_actions.dart";

/// Storage-choice step of first-run setup, and the "add another location"
/// screen from Storage & Volumes ([addingAnother]).
class OnboardingStorageScreen extends StatefulWidget {
  const OnboardingStorageScreen({this.addingAnother = false, super.key});

  /// Not first-run setup: no step counter, and once a location is added it
  /// goes back where it came from instead of on to the admin step.
  final bool addingAnother;

  @override
  State<OnboardingStorageScreen> createState() => _OnboardingStorageScreenState();
}

class _OnboardingStorageScreenState extends State<OnboardingStorageScreen> {
  bool _isWorking = false;
  AppFailure? _failure;

  Future<void> _useAppStorage() async {
    setState(() {
      _isWorking = true;
      _failure = null;
    });
    try {
      await addAppStorageRoot(context);
      if (!mounted) return;
      await _next();
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
      final String? rootId = await addSafStorageRoot(context);
      if (!mounted) return;
      // null = the person cancelled the system picker: stay on this screen.
      if (rootId != null) await _next();
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  /// Where to go once a location is added. The admin step is skipped when an
  /// admin already exists (it used to ask for one every time).
  Future<void> _next() async {
    if (widget.addingAnother) {
      context.pop();
      return;
    }
    final AccountRepository accounts = context.read<AccountRepository>();
    final bool hasAdmin = await accounts.countEnabledAdmins() > 0;
    if (!mounted) return;
    unawaited(context.push(hasAdmin ? "/onboarding/ready" : "/onboarding/admin"));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(widget.addingAnother ? "Add a storage location" : "Choose storage"),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (!widget.addingAnother) ...<Widget>[
                const AuroraStatusChip(label: "Step 2 of 3", status: AuroraStatus.idle),
                const SizedBox(height: AuroraSpacing.md),
              ],
              Text("Where should Atomic Carton keep your files?", style: AuroraTypography.headlineMd),
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
                            "A Downloads/Atomic-Carton folder you can find in any file manager. "
                            "May ask for \"All files access\".",
                            style: AuroraTypography.bodySm
                                .copyWith(color: context.inkSecondary),
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
                            "You'll be asked to grant Atomic Carton access to it.",
                            style: AuroraTypography.bodySm
                                .copyWith(color: context.inkSecondary),
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
