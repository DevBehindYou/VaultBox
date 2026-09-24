import "package:flutter/material.dart";

import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../domain/entities/ftp_settings.dart";

/// How to connect to the FTP server from the common places, with this phone's
/// own settings filled in.
Future<void> showFtpGuide(
  BuildContext context, {
  required String host,
  required FtpSettings settings,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => _FtpGuide(host: host, settings: settings),
  );
}

class _Step {
  const _Step(this.title, this.lines);

  final String title;
  final List<String> lines;
}

class _FtpGuide extends StatelessWidget {
  const _FtpGuide({required this.host, required this.settings});

  final String host;
  final FtpSettings settings;

  String get _security => switch (settings.mode) {
    FtpMode.explicitTls => "Require explicit FTP over TLS (FTPES / “FTP with TLS”)",
    FtpMode.implicitTls => "Implicit FTP over TLS (FTPS)",
    FtpMode.plain => "Plain FTP (no encryption)",
  };

  List<_Step> get _steps => <_Step>[
    _Step("Another phone (Solid Explorer, MiXplorer, CX, FX…)", <String>[
      "Add a new storage or network location and choose FTP (or “FTP(S, ES)”).",
      "Host: $host   Port: ${settings.port}",
      "Security: $_security.",
      if (settings.usesTls) "Accept the certificate when asked: it is Atomic Carton's own.",
      "Turn passive mode on (it usually is by default).",
      "Sign in with a Atomic Carton account's username and password.",
    ]),
    _Step("Windows, Mac or Linux (FileZilla, WinSCP, Cyberduck)", <String>[
      "New connection ▸ protocol FTP. Host $host, port ${settings.port}.",
      "Encryption: $_security.",
      "Transfer mode: passive.",
      "Sign in with a Atomic Carton account.",
    ]),
    _Step("A camera, scanner or older device", <String>[
      "Use the same host and port, and the encryption it supports.",
      if (settings.mode == FtpMode.plain)
        "Plain FTP is switched on, so this works — but passwords travel unencrypted. Use it only on a network you trust."
      else
        "Many older devices can only do plain FTP, which is switched off here. Devices that support implicit FTPS "
            "need that mode chosen in Atomic Carton.",
    ]),
    _Step("If it won't connect", <String>[
      "Both devices must be on the same Wi-Fi, and “Allow other devices on my network” must be on.",
      "Files travel over ports ${settings.passiveStart}–${settings.passiveEnd}. A router or firewall in between must allow them.",
      "Wrong password three times closes the connection, and repeated failures lock that account for a while.",
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AuroraSpacing.marginCompact, 0, AuroraSpacing.marginCompact, AuroraSpacing.md),
          shrinkWrap: true,
          children: <Widget>[
            Text("Connect with FTP", style: context.brand(26)),
            const SizedBox(height: 2),
            Text("ftp://$host:${settings.port}", style: context.mono(size: 12, color: context.inkPrimary)),
            const SizedBox(height: AuroraSpacing.md),
            for (final _Step step in _steps) ...<Widget>[
              Text(step.title, style: context.body.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              for (int i = 0; i < step.lines.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(width: 20, child: Text("${i + 1}.", style: context.mono(size: 12))),
                      Expanded(child: Text(step.lines[i], style: context.bodySecondary)),
                    ],
                  ),
                ),
              const SizedBox(height: AuroraSpacing.md),
            ],
          ],
        ),
      ),
    );
  }
}
