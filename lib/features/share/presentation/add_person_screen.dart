import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "../../../app/app_state.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/errors/app_failure.dart";
import "../../../domain/entities/account.dart";
import "../../../domain/security/password_policy.dart";
import "../../../domain/security/username_policy.dart";
import "../../../domain/usecases/manage_accounts.dart";

/// Adds a member: someone who can sign in but only reaches the folders they are
/// given afterwards (see the person's page).
///
/// Live feedback comes from the same policies the use case enforces. The
/// controllers belong to this State and die with it.
class AddPersonScreen extends StatefulWidget {
  const AddPersonScreen({required this.onDone, super.key});

  /// Called with the new account once it exists.
  final void Function(BuildContext context, Account account) onDone;

  @override
  State<AddPersonScreen> createState() => _AddPersonScreenState();
}

class _AddPersonScreenState extends State<AddPersonScreen> {
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
      final Account created = await context.read<CreateUserAccount>().call(
        username: _username.text,
        password: _password.text,
      );
      context.read<AccountsCubit>().refresh();
      if (!mounted) return;
      widget.onDone(context, created);
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
      appBar: AppBar(title: const Text("Add a person")),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                "They sign in on the web page or a WebDAV app with this name and password. "
                "They see nothing until you give them a folder.",
                style: AuroraTypography.bodyMd.copyWith(color: context.inkSecondary),
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
                label: _working ? "Adding…" : "Add person",
                icon: Icons.check,
                onPressed: _canSubmit ? () => unawaited(_submit()) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
