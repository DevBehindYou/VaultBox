import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/providers.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/errors/app_failure.dart";
import "../../../domain/entities/access_rule.dart";
import "../../../domain/entities/account.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/models/file_ref.dart";
import "../../../domain/security/password_policy.dart";
import "../../../domain/security/permission.dart";
import "../../../domain/usecases/manage_accounts.dart";
import "../../files/presentation/destination_picker_screen.dart";
import "../../files/viewmodel/files_view_model.dart";

/// One person: turn their access on/off, reset their password, choose which
/// folders they may reach, or remove them.
class PersonScreen extends ConsumerStatefulWidget {
  const PersonScreen({required this.accountId, required this.onRemoved, super.key});

  final String accountId;

  /// Called after the person was removed (the screen has nothing left to show).
  final void Function(BuildContext context) onRemoved;

  @override
  ConsumerState<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends ConsumerState<PersonScreen> {
  AppFailure? _failure;

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _failure = null);
    } on AppFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    }
    ref.invalidate(accountsProvider);
  }

  Future<void> _toggle(Account account, bool enabled) =>
      _guard(() => ref.read(setAccountEnabledProvider).call(accountId: account.id, enabled: enabled));

  Future<void> _resetPassword(Account account) async {
    final String? password = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => _NewPasswordDialog(username: account.username),
    );
    if (password == null) return;
    await _guard(() => ref.read(changePasswordProvider).call(accountId: account.id, newPassword: password));
    if (!mounted || _failure != null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Password changed. They'll need to sign in again.")),
    );
  }

  Future<void> _remove(Account account) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text("Remove ${account.username}?"),
        content: const Text("They can no longer sign in, and any links they made stop working."),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text("Keep")),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text("Remove")),
        ],
      ),
    );
    if (yes != true) return;
    await _guard(() => ref.read(deleteAccountProvider).call(accountId: account.id));
    if (!mounted || _failure != null) return;
    ref.invalidate(sharesProvider);
    widget.onRemoved(context);
  }

  Future<void> _saveRules(Account account, List<AccessGrantInput> grants) =>
      _guard(() => ref.read(setAccessRulesProvider).call(accountId: account.id, grants: grants));

  List<AccessGrantInput> _grantsOf(Account account) => <AccessGrantInput>[
    for (final AccessRule rule in account.rules)
      AccessGrantInput(rootId: rule.rootId, path: rule.pathPrefix, permissions: rule.permissions),
  ];

  Future<void> _addFolder(Account account, List<StorageRoot> roots) async {
    if (roots.isEmpty) return;
    final FileRef? folder = await pickDestination(context, initialDirectory: rootRef(roots.first));
    if (folder == null || !mounted) return;

    final Set<Permission>? permissions = await showDialog<Set<Permission>>(
      context: context,
      builder: (BuildContext dialogContext) => _PermissionsDialog(folderName: folder.path.isRoot ? folder.root.displayName : folder.path.name),
    );
    if (permissions == null) return;

    await _saveRules(account, <AccessGrantInput>[
      ..._grantsOf(account),
      AccessGrantInput(
        rootId: folder.root.id,
        path: folder.path.isRoot ? "/" : folder.path.normalized,
        permissions: permissions,
      ),
    ]);
  }

  Future<void> _removeRule(Account account, AccessRule rule) => _saveRules(account, <AccessGrantInput>[
    for (final AccessRule other in account.rules)
      if (other.id != rule.id)
        AccessGrantInput(rootId: other.rootId, path: other.pathPrefix, permissions: other.permissions),
  ]);

  String _describe(AccessRule rule, List<StorageRoot> roots) {
    final String root =
        roots.where((StorageRoot r) => r.id == rule.rootId).map((StorageRoot r) => r.displayName).firstOrNull ??
        "Unknown storage";
    return rule.pathPrefix == "/" ? "$root · everything" : "$root · ${rule.pathPrefix}";
  }

  static String _permissionWords(Set<Permission> permissions) {
    return <String>[
      if (permissions.contains(Permission.read)) "View",
      if (permissions.contains(Permission.write)) "Add & edit",
      if (permissions.contains(Permission.delete)) "Delete",
    ].join(" · ");
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Account>> accounts = ref.watch(accountsProvider);
    final List<StorageRoot> roots = ref.watch(storageRootsProvider).value ?? const <StorageRoot>[];

    return Scaffold(
      appBar: AppBar(title: const Text("Person")),
      body: SafeArea(
        child: accounts.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, StackTrace trace) => const Center(child: Text("Couldn't load this person.")),
          data: (List<Account> list) {
            final Account? account = list.where((Account a) => a.id == widget.accountId).firstOrNull;
            if (account == null) return const Center(child: Text("This person no longer exists."));

            return ListView(
              padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
              children: <Widget>[
                Text(account.username, style: AuroraTypography.headlineLg),
                const SizedBox(height: AuroraSpacing.xs),
                Wrap(
                  spacing: AuroraSpacing.sm,
                  children: <Widget>[
                    AuroraStatusChip(label: account.isAdmin ? "Admin" : "Member", status: AuroraStatus.idle),
                    if (!account.isEnabled) const AuroraStatusChip(label: "Turned off", status: AuroraStatus.warning),
                  ],
                ),
                const SizedBox(height: AuroraSpacing.md),
                if (_failure != null) ...<Widget>[
                  AuroraInlineBanner(
                    message: _failure!.message,
                    status: AuroraStatus.danger,
                    onDismiss: () => setState(() => _failure = null),
                  ),
                  const SizedBox(height: AuroraSpacing.md),
                ],
                AuroraCard(
                  child: Column(
                    children: <Widget>[
                      // SwitchListTile paints on the nearest Material; the card's
                      // coloured box needs its own transparent one.
                      Material(
                        type: MaterialType.transparency,
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text("Allowed to sign in"),
                          subtitle: Text(
                            account.isEnabled
                                ? "Turning this off signs them out at once."
                                : "They can't sign in until you turn this on.",
                          ),
                          value: account.isEnabled,
                          onChanged: (bool on) => unawaited(_toggle(account, on)),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => unawaited(_resetPassword(account)),
                          icon: const Icon(Icons.key_outlined),
                          label: const Text("Set a new password"),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AuroraSpacing.lg),
                if (account.isAdmin)
                  AuroraCard(
                    child: Text(
                      "Admins can reach everything on this phone, so there are no folder "
                      "settings to choose.",
                      style: AuroraTypography.bodyMd.copyWith(color: AuroraColors.inkSecondary),
                    ),
                  )
                else ...<Widget>[
                  Text("Folders they can reach", style: AuroraTypography.headlineSm),
                  const SizedBox(height: AuroraSpacing.sm),
                  if (account.rules.isEmpty)
                    const AuroraCard(child: Text("None yet — they can sign in but won't see any files."))
                  else
                    for (final AccessRule rule in account.rules) ...<Widget>[
                      AuroraCard(
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(_describe(rule, roots), style: AuroraTypography.bodyMd),
                                  Text(
                                    _permissionWords(rule.permissions),
                                    style: AuroraTypography.bodySm.copyWith(color: AuroraColors.inkSecondary),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: "Remove this folder",
                              icon: const Icon(Icons.close),
                              onPressed: () => unawaited(_removeRule(account, rule)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AuroraSpacing.sm),
                    ],
                  const SizedBox(height: AuroraSpacing.sm),
                  AuroraPrimaryButton(
                    label: "Give access to a folder",
                    icon: Icons.create_new_folder_outlined,
                    onPressed: roots.isEmpty ? null : () => unawaited(_addFolder(account, roots)),
                  ),
                ],
                const SizedBox(height: AuroraSpacing.xl),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: AuroraColors.statusDanger),
                    onPressed: () => unawaited(_remove(account)),
                    icon: const Icon(Icons.person_remove_outlined),
                    label: const Text("Remove this person"),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Asks for a new password (with confirmation). Controllers belong to this State.
class _NewPasswordDialog extends StatefulWidget {
  const _NewPasswordDialog({required this.username});

  final String username;

  @override
  State<_NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<_NewPasswordDialog> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? get _problem => _password.text.isEmpty ? null : PasswordPolicy.validate(_password.text, username: widget.username);

  bool get _ok => _password.text.isNotEmpty && _problem == null && _confirm.text == _password.text;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text("New password for ${widget.username}"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: "New password", errorText: _problem),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AuroraSpacing.md),
          TextField(
            controller: _confirm,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: "Confirm password",
              errorText: _confirm.text.isNotEmpty && _confirm.text != _password.text ? "The passwords don't match." : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
        FilledButton(
          onPressed: _ok ? () => Navigator.of(context).pop(_password.text) : null,
          child: const Text("Change password"),
        ),
      ],
    );
  }
}

/// What a person may do in a folder. Viewing is always included.
class _PermissionsDialog extends StatefulWidget {
  const _PermissionsDialog({required this.folderName});

  final String folderName;

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  bool _write = false;
  bool _delete = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text("Access to “${widget.folderName}”"),
      content: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CheckboxListTile(
              value: true,
              onChanged: null,
              title: Text("View and download"),
              subtitle: Text("Always included."),
            ),
            CheckboxListTile(
              value: _write,
              onChanged: (bool? on) => setState(() {
                _write = on ?? false;
                if (!_write) _delete = false;
              }),
              title: const Text("Add and change"),
              subtitle: const Text("Upload, create folders, rename."),
            ),
            CheckboxListTile(
              value: _delete,
              onChanged: _write ? (bool? on) => setState(() => _delete = on ?? false) : null,
              title: const Text("Delete"),
              subtitle: const Text("Deleted files go to the Recycle Bin."),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(<Permission>{
            Permission.read,
            if (_write) Permission.write,
            if (_delete) Permission.delete,
          }),
          child: const Text("Give access"),
        ),
      ],
    );
  }
}
