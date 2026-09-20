import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "../../../app/providers.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../domain/entities/account.dart";
import "../../../domain/entities/share.dart";
import "../share_links.dart";

/// The Share tab: links made for people without an account, and the people who
/// have one. Making a link starts from Files (select an item, tap Share).
class ShareScreen extends ConsumerStatefulWidget {
  const ShareScreen({super.key});

  @override
  ConsumerState<ShareScreen> createState() => _ShareScreenState();
}

enum _Section { links, people }

class _ShareScreenState extends ConsumerState<ShareScreen> {
  _Section _section = _Section.links;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text("Share", style: AuroraTypography.headlineLg),
              const SizedBox(height: AuroraSpacing.md),
              SegmentedButton<_Section>(
                segments: const <ButtonSegment<_Section>>[
                  ButtonSegment<_Section>(value: _Section.links, label: Text("Links"), icon: Icon(Icons.link)),
                  ButtonSegment<_Section>(value: _Section.people, label: Text("People"), icon: Icon(Icons.group_outlined)),
                ],
                selected: <_Section>{_section},
                onSelectionChanged: (Set<_Section> chosen) => setState(() => _section = chosen.first),
              ),
              const SizedBox(height: AuroraSpacing.md),
              Expanded(child: _section == _Section.links ? const _LinksView() : const _PeopleView()),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ links

class _LinksView extends ConsumerWidget {
  const _LinksView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Share>> shares = ref.watch(sharesProvider);
    final DateTime now = ref.watch(clockProvider).now();

    return shares.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace trace) => const Text("Couldn't load your links."),
      data: (List<Share> list) {
        if (list.isEmpty) {
          return const AuroraCard(
            child: Text(
              "No links yet. In Files, select a file or folder and tap Share to make a "
              "link anyone can open — or Ask for files to let people send you some.",
            ),
          );
        }
        return ListView.separated(
          itemCount: list.length,
          separatorBuilder: (BuildContext context, int index) => const SizedBox(height: AuroraSpacing.sm),
          itemBuilder: (BuildContext context, int index) => _ShareCard(share: list[index], now: now),
        );
      },
    );
  }
}

class _ShareCard extends ConsumerWidget {
  const _ShareCard({required this.share, required this.now});

  final Share share;
  final DateTime now;

  Future<void> _revoke(BuildContext context, WidgetRef ref) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text("Turn this link off?"),
        content: const Text("Anyone who has it will stop being able to use it. This can't be undone."),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text("Keep")),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text("Turn off")),
        ],
      ),
    );
    if (yes != true) return;
    await ref.read(shareRepositoryProvider).delete(share.id);
    ref.invalidate(sharesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool active = share.isActive(now);
    final String uses = share.maxUses == null
        ? "${share.useCount} ${share.kind == ShareKind.upload ? "received" : "downloads"}"
        : "${share.useCount} of ${share.maxUses} ${share.kind == ShareKind.upload ? "files" : "downloads"}";

    return AuroraCard(
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  share.label ?? share.path,
                  style: AuroraTypography.headlineSm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AuroraSpacing.xs),
                Wrap(
                  spacing: AuroraSpacing.sm,
                  runSpacing: AuroraSpacing.xs,
                  children: <Widget>[
                    AuroraStatusChip(
                      label: share.kind == ShareKind.upload ? "Upload" : "Download",
                      status: AuroraStatus.idle,
                    ),
                    AuroraStatusChip(
                      label: describeShareState(share, now),
                      status: active ? AuroraStatus.live : AuroraStatus.warning,
                    ),
                    if (share.hasPassword) const AuroraStatusChip(label: "Password", status: AuroraStatus.idle),
                  ],
                ),
                const SizedBox(height: AuroraSpacing.xs),
                Text(
                  "${describeExpiry(share.expiresAt, now)} · $uses",
                  style: AuroraTypography.bodySm.copyWith(color: AuroraColors.inkSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: "Turn this link off",
            icon: const Icon(Icons.link_off),
            onPressed: () => unawaited(_revoke(context, ref)),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- people

class _PeopleView extends ConsumerWidget {
  const _PeopleView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Account>> accounts = ref.watch(accountsProvider);

    return accounts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace trace) => const Text("Couldn't load the people list."),
      data: (List<Account> list) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (list.isEmpty)
            const AuroraCard(
              child: Text("No accounts yet. Create the admin account on the Home tab first."),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: list.length,
                separatorBuilder: (BuildContext context, int index) => const SizedBox(height: AuroraSpacing.sm),
                itemBuilder: (BuildContext context, int index) => _PersonCard(account: list[index]),
              ),
            ),
          if (list.isNotEmpty) ...<Widget>[
            const SizedBox(height: AuroraSpacing.md),
            AuroraPrimaryButton(
              label: "Add a person",
              icon: Icons.person_add_alt,
              onPressed: () => unawaited(context.push("/people/new")),
            ),
          ],
        ],
      ),
    );
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) {
    return AuroraCard(
      onTap: () => unawaited(context.push("/people/${account.id}")),
      child: Row(
        children: <Widget>[
          const Icon(Icons.account_circle_outlined),
          const SizedBox(width: AuroraSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(account.username, style: AuroraTypography.headlineSm),
                const SizedBox(height: AuroraSpacing.xs),
                Wrap(
                  spacing: AuroraSpacing.sm,
                  children: <Widget>[
                    AuroraStatusChip(
                      label: account.isAdmin ? "Admin" : "Member",
                      status: AuroraStatus.idle,
                    ),
                    if (!account.isEnabled) const AuroraStatusChip(label: "Turned off", status: AuroraStatus.warning),
                    if (!account.isAdmin)
                      AuroraStatusChip(
                        label: account.rules.length == 1 ? "1 folder" : "${account.rules.length} folders",
                        status: AuroraStatus.idle,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}
