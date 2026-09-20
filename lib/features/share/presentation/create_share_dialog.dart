import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:qr_flutter/qr_flutter.dart";

import "../../../app/providers.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/errors/app_failure.dart";
import "../../../domain/entities/account.dart";
import "../../../domain/entities/server_state.dart";
import "../../../domain/entities/share.dart";
import "../../../domain/models/file_ref.dart";
import "../../../domain/usecases/create_share.dart";
import "../share_links.dart";

/// Makes a link for [target] and, once it exists, shows it (with a QR code).
///
/// A download link shares a file or folder; an upload link lets people send
/// files into a folder without seeing what is in it. The secret part of the
/// link is shown ONCE, here — afterwards only its hash exists on the phone.
Future<void> showCreateShareFlow(
  BuildContext context, {
  required FileRef target,
  required ShareKind kind,
  required String itemName,
}) async {
  final CreatedShare? created = await showDialog<CreatedShare>(
    context: context,
    builder: (BuildContext dialogContext) => _CreateShareDialog(target: target, kind: kind, itemName: itemName),
  );
  if (created == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => ShareCreatedDialog(created: created),
  );
}

class _CreateShareDialog extends ConsumerStatefulWidget {
  const _CreateShareDialog({required this.target, required this.kind, required this.itemName});

  final FileRef target;
  final ShareKind kind;
  final String itemName;

  @override
  ConsumerState<_CreateShareDialog> createState() => _CreateShareDialogState();
}

class _CreateShareDialogState extends ConsumerState<_CreateShareDialog> {
  static const List<(String, Duration?)> _lifetimes = <(String, Duration?)>[
    ("1 hour", Duration(hours: 1)),
    ("1 day", Duration(days: 1)),
    ("7 days", Duration(days: 7)),
    ("30 days", Duration(days: 30)),
    ("No expiry", null),
  ];

  static const List<(String, int?)> _fileSizes = <(String, int?)>[
    ("10 MB", 10 * 1024 * 1024),
    ("100 MB", 100 * 1024 * 1024),
    ("1 GB", 1024 * 1024 * 1024),
    ("No limit", null),
  ];

  final TextEditingController _password = TextEditingController();
  final TextEditingController _limit = TextEditingController();
  // Chosen by position: a null-valued dropdown item would render as "nothing selected".
  int _lifetimeIndex = 2; // 7 days
  int _fileSizeIndex = 1; // 100 MB
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _limit.dispose();
    super.dispose();
  }

  bool get _isUpload => widget.kind == ShareKind.upload;

  int? get _parsedLimit => _limit.text.trim().isEmpty ? null : int.tryParse(_limit.text.trim());

  String? get _limitProblem {
    if (_limit.text.trim().isEmpty) return null;
    final int? value = _parsedLimit;
    return value == null || value < 1 ? "Enter a whole number, 1 or more." : null;
  }

  String? get _passwordProblem {
    if (_password.text.isEmpty) return null;
    if (_password.text.length < CreateShare.minPasswordLength) {
      return "Use at least ${CreateShare.minPasswordLength} characters.";
    }
    return null;
  }

  Future<void> _submit() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final Account? owner = await ref.read(ownerAccountProvider.future);
      if (owner == null) {
        throw const ValidationFailure(message: "Create an admin account first (Home tab).");
      }
      final CreatedShare created = await ref.read(createShareProvider).call(
        creator: owner,
        kind: widget.kind,
        rootId: widget.target.root.id,
        path: widget.target.path.isRoot ? "/" : widget.target.path.normalized,
        lifetime: _lifetimes[_lifetimeIndex].$2,
        password: _password.text.isEmpty ? null : _password.text,
        maxUses: _parsedLimit,
        maxFileBytes: _isUpload ? _fileSizes[_fileSizeIndex].$2 : null,
        label: widget.itemName,
      );
      ref.invalidate(sharesProvider);
      if (!mounted) return;
      Navigator.of(context).pop(created);
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _error = failure.message;
        _working = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canSubmit = !_working && _limitProblem == null && _passwordProblem == null;

    return AlertDialog(
      title: Text(_isUpload ? "Ask for files" : "Share a link"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _isUpload
                  ? "Anyone with the link can send files into “${widget.itemName}”. "
                        "They can't see what is already there."
                  : "Anyone with the link can download “${widget.itemName}”, "
                        "without an account.",
              style: AuroraTypography.bodyMd.copyWith(color: context.inkSecondary),
            ),
            const SizedBox(height: AuroraSpacing.md),
            if (_error != null) ...<Widget>[
              Text(_error!, style: AuroraTypography.bodyMd.copyWith(color: context.statusDanger)),
              const SizedBox(height: AuroraSpacing.sm),
            ],
            DropdownButtonFormField<int>(
              initialValue: _lifetimeIndex,
              decoration: const InputDecoration(labelText: "Link works for"),
              items: <DropdownMenuItem<int>>[
                for (int i = 0; i < _lifetimes.length; i++)
                  DropdownMenuItem<int>(value: i, child: Text(_lifetimes[i].$1)),
              ],
              onChanged: _working ? null : (int? value) => setState(() => _lifetimeIndex = value ?? _lifetimeIndex),
            ),
            const SizedBox(height: AuroraSpacing.md),
            TextField(
              controller: _password,
              enabled: !_working,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: "Password (optional)",
                helperText: "People must type it to use the link.",
                errorText: _passwordProblem,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AuroraSpacing.md),
            TextField(
              controller: _limit,
              enabled: !_working,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: _isUpload ? "Most files (optional)" : "Most downloads (optional)",
                errorText: _limitProblem,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_isUpload) ...<Widget>[
              const SizedBox(height: AuroraSpacing.md),
              DropdownButtonFormField<int>(
                initialValue: _fileSizeIndex,
                decoration: const InputDecoration(labelText: "Biggest file"),
                items: <DropdownMenuItem<int>>[
                  for (int i = 0; i < _fileSizes.length; i++)
                    DropdownMenuItem<int>(value: i, child: Text(_fileSizes[i].$1)),
                ],
                onChanged: _working ? null : (int? value) => setState(() => _fileSizeIndex = value ?? _fileSizeIndex),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        FilledButton(
          onPressed: canSubmit ? () => unawaited(_submit()) : null,
          child: Text(_working ? "Creating…" : "Create link"),
        ),
      ],
    );
  }
}

/// Shows a new link once: the address, a QR code and a Copy button.
class ShareCreatedDialog extends ConsumerWidget {
  const ShareCreatedDialog({required this.created, super.key});

  final CreatedShare created;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerState server = ref.watch(serverStateProvider).value ?? const ServerState.stopped();
    final String? base = shareLinkBase(server);
    final String path = "${created.share.kind == ShareKind.download ? "s" : "u"}/${created.token}";
    final String text = base == null ? "…/$path" : shareUrl(base, created.share.kind, created.token);
    final bool unencrypted = base != null && isUnencrypted(text);

    return AlertDialog(
      title: const Text("Link ready"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              "Copy it now — for safety VaultBox keeps only a fingerprint of the link, "
              "so it can't be shown again.",
              style: AuroraTypography.bodyMd.copyWith(color: context.inkSecondary),
            ),
            const SizedBox(height: AuroraSpacing.md),
            SelectableText(text, style: AuroraTypography.tabularFigures(AuroraTypography.labelMonoMd)),
            if (base == null) ...<Widget>[
              const SizedBox(height: AuroraSpacing.sm),
              Text(
                "The server isn't running, so there's no address yet. Start it on the Home "
                "tab and put its address in front of the part above.",
                style: AuroraTypography.bodySm.copyWith(color: context.statusWarning),
              ),
            ] else ...<Widget>[
              const SizedBox(height: AuroraSpacing.md),
              Center(
                child: ColoredBox(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(AuroraSpacing.sm),
                    // A fixed box: the dialog measures its content's intrinsic size, which
                    // QrImageView (a LayoutBuilder) can't answer.
                    child: SizedBox(
                      width: 180,
                      height: 180,
                      child: QrImageView(data: text, size: 180, backgroundColor: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
            if (unencrypted) ...<Widget>[
              const SizedBox(height: AuroraSpacing.sm),
              Text(
                "This address is not encrypted — use it only on a network you trust.",
                style: AuroraTypography.bodySm.copyWith(color: context.statusWarning),
              ),
            ],
            if (created.share.hasPassword) ...<Widget>[
              const SizedBox(height: AuroraSpacing.sm),
              Text(
                "It asks for the password you chose. Send that separately.",
                style: AuroraTypography.bodySm.copyWith(color: context.inkSecondary),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Link copied")));
          },
          icon: const Icon(Icons.copy),
          label: const Text("Copy"),
        ),
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Done")),
      ],
    );
  }
}
