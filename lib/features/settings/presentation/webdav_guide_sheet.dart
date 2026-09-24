import "package:flutter/material.dart";

import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";

/// How to connect to the WebDAV address from the common places.
///
/// Written from how these apps actually behave. In particular, the built-in
/// Windows client refuses certificates a computer doesn't already trust, which
/// is what VaultBox's own certificate is, so the guide points to apps that let
/// you accept it.
Future<void> showWebDavGuide(BuildContext context, {required String address}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => _WebDavGuide(address: address),
  );
}

class _Step {
  const _Step(this.title, this.lines);

  final String title;
  final List<String> lines;
}

class _WebDavGuide extends StatelessWidget {
  const _WebDavGuide({required this.address});

  final String address;

  List<_Step> get _steps {
    final Uri? uri = Uri.tryParse(address);
    final String host = uri == null || uri.host.isEmpty ? "<phone address>" : uri.host;
    final String port = uri != null && uri.hasPort ? "${uri.port}" : "<port>";
    final bool secure = uri == null || uri.scheme != "http";
    return <_Step>[
      _Step("Another phone (Solid Explorer, MiXplorer, FX, CX…)", <String>[
        "Add a new storage or network location and choose WebDAV.",
        "Host: $host   Port: $port   Path: /dav",
        secure ? "Turn on HTTPS / SSL, and accept the certificate when asked." : "Leave HTTPS / SSL off (this address is plain HTTP).",
        "Sign in with a Atomic Carton account's username and password.",
      ]),
      _Step("Mac (Finder)", <String>[
        "Go ▸ Connect to Server (⌘K).",
        "Enter $address and press Connect.",
        "Sign in with a Atomic Carton account; accept the certificate if it warns you.",
      ]),
      _Step("Windows", <String>[
        "Use an app that lets you accept the certificate: WinSCP, Cyberduck or RaiDrive all support WebDAV.",
        "Choose WebDAV (HTTPS), host $host, port $port, path /dav.",
        "Windows' own “Map network drive” refuses certificates it doesn't already trust, so it won't connect to "
            "Atomic Carton's self-made certificate.",
      ]),
      _Step("Linux", <String>[
        "GNOME Files: Other Locations ▸ enter davs://$host:$port/dav",
        "KDE Dolphin: enter webdavs://$host:$port/dav",
        "Sign in with a Atomic Carton account; accept the certificate.",
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AuroraSpacing.marginCompact, 0, AuroraSpacing.marginCompact, AuroraSpacing.md),
          shrinkWrap: true,
          children: <Widget>[
            Text("Connect with WebDAV", style: context.brand(26)),
            const SizedBox(height: 2),
            Text(
              "Your address: $address",
              style: context.mono(size: 12, color: context.inkPrimary),
            ),
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
