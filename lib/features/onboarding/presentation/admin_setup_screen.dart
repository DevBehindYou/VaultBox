import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/providers.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/errors/app_failure.dart";
import "../../../domain/security/password_policy.dart";
import "../../../domain/security/username_policy.dart";

/// Creates the admin account (the one login the server accepts for now).
///
/// Used twice: as onboarding step 3 (with a "Skip for now") and from Home when
/// no admin exists yet. Live feedback comes from the SAME policies the use case
/// enforces, so the button can only be tapped with input the use case accepts.
///
/// The controllers are owned by this State and disposed with it — never in a
/// caller's `finally` (that crashed the New-folder dialog once).
class AdminSetupScreen extends ConsumerStatefulWidget {
  const AdminSetupScreen({
    required this.onDone,
    this.stepLabel,
    this.skipLabel,
    this.onSkip,
    super.key,
  });

  final void Function(BuildContext context) onDone;
  final String? stepLabel;
  final String? skipLabel;
  final void Function(BuildContext context)? onSkip;

  @override
  ConsumerState<AdminSetupScreen> createState() => _AdminSetupScreenState();
}

class _AdminSetupScreenState extends ConsumerState<AdminSetupScreen> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _showPassword = false;
  bool _working = false;
  AppFailure? _failure;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String get _name => UsernamePolicy.normalize(_username.text);

  String? get _usernameProblem => _username.text.isEmpty ? null : UsernamePolicy.validate(_name);

  String? get _passwordProblem =>
      _password.text.isEmpty ? null : PasswordPolicy.validate(_password.text, username: _name);

  String? get _confirmProblem =>
      _confirm.text.isNotEmpty && _confirm.text != _password.text ? "The passwords don't match." : null;

  bool get _canSubmit =>
      !_working &&
      _username.text.isNotEmpty &&
      _usernameProblem == null &&
      _password.text.isNotEmpty &&
      _passwordProblem == null &&
      _confirm.text == _password.text;

  Future<void> _submit() async {
    setState(() {
      _working = true;
      _failure = null;
    });
    try {
      await ref.read(createAdminAccountProvider).call(
        username: _username.text,
        password: _password.text,
      );
      ref.invalidate(adminExistsProvider);
      if (!mounted) return;
      widget.onDone(context);
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Admin account")),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (widget.stepLabel != null) ...<Widget>[
                AuroraStatusChip(label: widget.stepLabel!, status: AuroraStatus.idle),
                const SizedBox(height: AuroraSpacing.md),
              ],
              Text("Create your admin account", style: AuroraTypography.headlineMd),
              const SizedBox(height: AuroraSpacing.sm),
              Text(
                "This is the login for VaultBox's server. Choose a long passphrase — "
                "it is stored only as a salted hash and can't be recovered.",
                style: AuroraTypography.bodyMd.copyWith(color: AuroraColors.inkSecondary),
              ),
              const SizedBox(height: AuroraSpacing.lg),
              if (_failure != null) ...<Widget>[
                AuroraInlineBanner(
                  message: _failure!.message,
                  status: AuroraStatus.danger,
                  onDismiss: () => setState(() => _failure = null),
                ),
                const SizedBox(height: AuroraSpacing.md),
              ],
              TextField(
                controller: _username,
                enabled: !_working,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: "Username", errorText: _usernameProblem),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AuroraSpacing.md),
              TextField(
                controller: _password,
                enabled: !_working,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: "Password",
                  helperText: "At least ${PasswordPolicy.minLength} characters.",
                  errorText: _passwordProblem,
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? "Hide password" : "Show password",
                    icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showPassword = !_showPassword),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AuroraSpacing.md),
              TextField(
                controller: _confirm,
                enabled: !_working,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: "Confirm password", errorText: _confirmProblem),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (_canSubmit) unawaited(_submit());
                },
              ),
              const SizedBox(height: AuroraSpacing.lg),
              AuroraPrimaryButton(
                label: _working ? "Creating…" : "Create account",
                icon: Icons.check,
                onPressed: _canSubmit ? () => unawaited(_submit()) : null,
              ),
              if (widget.skipLabel != null && widget.onSkip != null) ...<Widget>[
                const SizedBox(height: AuroraSpacing.sm),
                Center(
                  child: TextButton(
                    onPressed: _working ? null : () => widget.onSkip!(context),
                    child: Text(widget.skipLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
