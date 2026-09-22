import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:go_router/go_router.dart";

import "../../../app/app_state.dart";
import "../../../core/design/aurora_components.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/errors/app_failure.dart";
import "../../../domain/entities/account.dart";
import "../../../domain/entities/activity.dart";
import "../../../domain/entities/server_config.dart";
import "../../../domain/entities/share.dart";
import "../../../domain/repositories/account_repository.dart";
import "../../../domain/repositories/clock.dart";
import "../../activity/activity_format.dart";
import "../security_checklist.dart";

/// Security & Sessions: which protections are in place (judged from the real
/// settings), who is signed in and how to end their sessions, how many sign-ins
/// were refused lately, and the certificate to compare against a browser's warning.
class SecurityScreen extends StatelessWidget {
  const SecurityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final DateTime now = context.read<Clock>().now();
    final ServerConfig config = context.watch<ServerConfigCubit>().state.value ?? const ServerConfig();
    final bool adminExists = context.watch<AdminExistsCubit>().state.value ?? false;
    final List<Share> shares = context.watch<SharesCubit>().state.value ?? const <Share>[];
    final List<SecurityItem> items = buildSecurityChecklist(
      config: config,
      adminExists: adminExists,
      shares: shares,
      now: now,
    );
    final int good = items.where((SecurityItem i) => i.isGood).length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AuroraSpacing.marginCompact,
          AuroraSpacing.sm,
          AuroraSpacing.marginCompact,
          AuroraSpacing.dockScrollClearance,
        ),
        children: <Widget>[
          const AuroraSubHeader(
            title: "Security & Sessions",
            subtitle: "What protects your files, and who is signed in.",
          ),
          AuroraCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: Text("Protection checklist", style: context.brand(22))),
                    _ScoreTag(good: good, total: items.length),
                  ],
                ),
                const SizedBox(height: 2),
                Text("$good of ${items.length} protections fully in place.", style: context.bodySecondary),
                const SizedBox(height: AuroraSpacing.sm),
                for (final SecurityItem item in items) _ChecklistRow(item: item),
              ],
            ),
          ),
          const AuroraSectionHeader(title: "Signed-in devices"),
          const _SessionsCard(),
          const AuroraSectionHeader(title: "Guessing protection"),
          const _IntrusionCard(),
          const AuroraSectionHeader(title: "Certificate"),
          const _CertificateCard(),
        ],
      ),
    );
  }
}

class _ScoreTag extends StatelessWidget {
  const _ScoreTag({required this.good, required this.total});

  final int good;
  final int total;

  @override
  Widget build(BuildContext context) {
    final bool all = good == total;
    final Color color = all ? context.statusSuccess : context.statusWarning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.pillAll),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(all ? Icons.verified_outlined : Icons.info_outline, size: 14, color: color),
          const SizedBox(width: 4),
          Text(all ? "Protected" : "Review", style: context.mono(size: 11, color: color, weight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({required this.item});

  final SecurityItem item;

  @override
  Widget build(BuildContext context) {
    final Color color = item.isGood ? context.statusSuccess : context.statusWarning;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(item.isGood ? Icons.check_circle_outline : Icons.error_outline, size: 20, color: color),
          const SizedBox(width: AuroraSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.title, style: context.body.copyWith(fontWeight: FontWeight.w600)),
                Text(item.detail, style: context.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- sessions

class _SessionsCard extends StatelessWidget {
  const _SessionsCard();

  Future<void> _signOut(BuildContext context, String username) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text("Sign $username out?"),
        content: Text(
          "$username is signed out on every device at once. They can sign in again with their password.",
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text("Keep")),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text("Sign out")),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    final AccountRepository accountRepository = context.read<AccountRepository>();
    try {
      final Account? account = await accountRepository.findByUsername(username);
      if (account != null) await accountRepository.revokeSessions(account.id);
      if (!context.mounted) return;
      unawaited(context.read<AccountsCubit>().refresh());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$username was signed out everywhere.")));
    } on AppFailure catch (failure) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  Future<void> _signOutEveryone(BuildContext context) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text("Sign everyone out?"),
        content: const Text(
          "Every person is signed out on every device, including the web page you may have open. "
          "Nothing is deleted, and everyone can sign in again.",
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text("Keep")),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text("Sign everyone out")),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    final AccountRepository accountRepository = context.read<AccountRepository>();
    final List<Account> accounts = await accountRepository.listAll();
    for (final Account account in accounts) {
      await accountRepository.revokeSessions(account.id);
    }
    if (!context.mounted) return;
    unawaited(context.read<AccountsCubit>().refresh());
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Everyone was signed out.")));
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = context.read<Clock>().now();
    final List<ClientRecord> clients = context.watch<ActivityClientsCubit>().state.value ?? const <ClientRecord>[];

    if (clients.isEmpty) {
      return const AuroraEmptyState(
        icon: Icons.devices_outlined,
        title: "Nobody is signed in",
        message: "People who sign in from a browser or a WebDAV app in the last day show up here.",
      );
    }

    return Column(
      children: <Widget>[
        for (final ClientRecord client in clients) ...<Widget>[
          AuroraCard(
            child: Row(
              children: <Widget>[
                Icon(
                  switch (client.via) {
                    AccessVia.web => Icons.language,
                    AccessVia.webdav => Icons.folder_shared_outlined,
                    AccessVia.link => Icons.link,
                    AccessVia.ftp => Icons.dns_outlined,
                  },
                  color: context.scheme.primary,
                ),
                const SizedBox(width: AuroraSpacing.sm + 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(client.actor, style: AuroraTypography.headlineSm.copyWith(color: context.inkPrimary)),
                      Text("${describeVia(client.via)} · ${client.address}", style: context.mono(size: 11)),
                      Text(
                        now.difference(client.lastSeenAt) < clientActiveWithin
                            ? "Active now"
                            : "Last active ${describeAgo(client.lastSeenAt, now)}",
                        style: context.caption,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(_signOut(context, client.actor)),
                  child: Text("Sign out", style: TextStyle(color: context.statusDanger)),
                ),
              ],
            ),
          ),
          const SizedBox(height: AuroraSpacing.sm),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => unawaited(_signOutEveryone(context)),
            icon: Icon(Icons.logout, size: 18, color: context.statusDanger),
            label: Text("Sign everyone out", style: TextStyle(color: context.statusDanger)),
          ),
        ),
      ],
    );
  }
}

// --------------------------------------------------------------- intrusion

class _IntrusionCard extends StatelessWidget {
  const _IntrusionCard();

  @override
  Widget build(BuildContext context) {
    final DateTime now = context.read<Clock>().now();
    final List<ActivityEvent> events = context.watch<ActivityEventsCubit>().state.value ?? const <ActivityEvent>[];
    final int refused = events
        .where(
          (ActivityEvent e) =>
              e.kind == ActivityKind.signInRefused && now.difference(e.at) < const Duration(days: 7),
        )
        .length;

    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            "After a few wrong passwords, sign-in is locked for that account and for that address, and the lock "
            "gets longer each time. Nothing has to be switched on for this.",
            style: context.bodySecondary,
          ),
          const SizedBox(height: AuroraSpacing.sm),
          Row(
            children: <Widget>[
              Icon(
                refused == 0 ? Icons.shield_outlined : Icons.warning_amber_outlined,
                color: refused == 0 ? context.statusSuccess : context.statusWarning,
              ),
              const SizedBox(width: AuroraSpacing.sm),
              Expanded(
                child: Text(
                  refused == 0
                      ? "No refused sign-ins in the last 7 days."
                      : "$refused refused sign-in ${refused == 1 ? "event" : "events"} in the last 7 days.",
                  style: context.body,
                ),
              ),
            ],
          ),
          const SizedBox(height: AuroraSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => context.go("/activity"), child: const Text("Open the Activity log")),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- certificate

class _CertificateCard extends StatelessWidget {
  const _CertificateCard();

  @override
  Widget build(BuildContext context) {
    final String? fingerprint = context.watch<TlsFingerprintCubit>().state.value;
    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            "Browsers warn about this certificate because VaultBox made it itself. Before you trust it, "
            "compare this fingerprint with the one the browser shows.",
            style: context.bodySecondary,
          ),
          const SizedBox(height: AuroraSpacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.mdAll),
            child: fingerprint == null
                ? Text("Not available yet.", style: context.caption)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text("SHA-256 FINGERPRINT", style: context.mono(size: 10, color: context.inkTertiary).copyWith(letterSpacing: 0.6)),
                      const SizedBox(height: 4),
                      SelectableText(fingerprint, style: context.mono(size: 12, color: context.inkPrimary)),
                    ],
                  ),
          ),
          if (fingerprint != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: fingerprint));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Fingerprint copied")));
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text("Copy fingerprint"),
              ),
            ),
        ],
      ),
    );
  }
}
