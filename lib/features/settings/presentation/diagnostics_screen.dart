import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/providers.dart";
import "../../../core/app_info.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../domain/entities/diagnostic.dart";
import "../../../domain/entities/server_config.dart";
import "../../../domain/entities/server_state.dart";
import "../../../domain/repositories/server_host.dart";
import "../../../domain/usecases/build_support_bundle.dart";

/// Runs the health checks and shows each result in plain words, with what to do
/// about anything that isn't fine. Also copies a support bundle (see
/// [buildSupportBundle] for what it leaves out).
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  List<DiagnosticCheck>? _checks;
  bool _running = true; // the first run starts in initState

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    if (!_running) setState(() => _running = true);
    List<DiagnosticCheck> results;
    try {
      results = await ref.read(runDiagnosticsProvider).call();
    } on Object {
      results = const <DiagnosticCheck>[
        DiagnosticCheck(
          title: "Checks",
          status: DiagnosticStatus.problem,
          detail: "The checks couldn't be run.",
          hint: "Close and reopen VaultBox, then try again.",
        ),
      ];
    }
    if (!mounted) return;
    setState(() {
      _checks = results;
      _running = false;
    });
  }

  Future<void> _copyBundle() async {
    final List<DiagnosticCheck>? checks = _checks;
    if (checks == null) return;
    final ServerHost host = ref.read(serverHostProvider);
    ServerState state;
    ServerConfig config;
    try {
      state = await host.watch().first.timeout(const Duration(seconds: 3));
      config = await host.config();
    } on Object {
      state = const ServerState.stopped();
      config = const ServerConfig();
    }
    final String bundle = buildSupportBundle(
      now: ref.read(clockProvider).now(),
      appVersion: appVersion,
      server: state,
      config: config,
      checks: checks,
      events: await ref.read(activityRepositoryProvider).recentEvents(limit: 50),
      transfers: await ref.read(activityRepositoryProvider).recentTransfers(limit: 100),
    );
    await Clipboard.setData(ClipboardData(text: bundle));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Support bundle copied. It names no people, files or addresses.")),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<DiagnosticCheck>? checks = _checks;
    final int trouble = checks == null
        ? 0
        : checks.where((DiagnosticCheck c) => c.status != DiagnosticStatus.ok).length;

    return Scaffold(
      appBar: AppBar(title: const Text("Diagnostics")),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
          children: <Widget>[
            if (checks == null)
              const Center(child: CircularProgressIndicator())
            else ...<Widget>[
              AuroraInlineBanner(
                message: trouble == 0
                    ? "Everything looks fine."
                    : trouble == 1
                    ? "1 thing needs a look."
                    : "$trouble things need a look.",
                status: trouble == 0 ? AuroraStatus.live : AuroraStatus.warning,
              ),
              const SizedBox(height: AuroraSpacing.md),
              for (final DiagnosticCheck check in checks) ...<Widget>[
                _CheckCard(check: check),
                const SizedBox(height: AuroraSpacing.sm),
              ],
            ],
            const SizedBox(height: AuroraSpacing.md),
            AuroraPrimaryButton(
              label: _running ? "Checking…" : "Run the checks again",
              icon: Icons.refresh,
              onPressed: _running ? null : () => unawaited(_run()),
            ),
            const SizedBox(height: AuroraSpacing.sm),
            OutlinedButton.icon(
              onPressed: checks == null ? null : () => unawaited(_copyBundle()),
              icon: const Icon(Icons.copy),
              label: const Text("Copy support bundle"),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckCard extends StatelessWidget {
  const _CheckCard({required this.check});

  final DiagnosticCheck check;

  @override
  Widget build(BuildContext context) {
    final (String label, AuroraStatus status) = switch (check.status) {
      DiagnosticStatus.ok => ("OK", AuroraStatus.live),
      DiagnosticStatus.warning => ("Look", AuroraStatus.warning),
      DiagnosticStatus.problem => ("Problem", AuroraStatus.danger),
    };
    final String? subject = check.subject;
    final String? hint = check.hint;

    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  subject == null ? check.title : "${check.title} · $subject",
                  style: AuroraTypography.headlineSm,
                ),
              ),
              AuroraStatusChip(label: label, status: status),
            ],
          ),
          const SizedBox(height: AuroraSpacing.xs),
          Text(check.detail, style: AuroraTypography.bodyMd),
          if (hint != null && check.status != DiagnosticStatus.ok) ...<Widget>[
            const SizedBox(height: AuroraSpacing.xs),
            Text(hint, style: AuroraTypography.bodySm.copyWith(color: AuroraColors.inkSecondary)),
          ],
        ],
      ),
    );
  }
}
