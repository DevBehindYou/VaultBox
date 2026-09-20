import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:qr_flutter/qr_flutter.dart";

import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../share/share_links.dart";

/// A QR code for the server's web address, so another device can open it by
/// scanning instead of typing.
Future<void> showServerQrSheet(BuildContext context, String address) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AuroraSpacing.marginCompact,
          0,
          AuroraSpacing.marginCompact,
          AuroraSpacing.marginCompact,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text("Open on another device", style: AuroraTypography.headlineMd),
            const SizedBox(height: AuroraSpacing.sm),
            Text(
              "Scan this with a phone or tablet on the same Wi-Fi, or type the address into a browser.",
              textAlign: TextAlign.center,
              style: AuroraTypography.bodyMd.copyWith(color: context.inkSecondary),
            ),
            const SizedBox(height: AuroraSpacing.md),
            ColoredBox(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(AuroraSpacing.sm),
                child: QrImageView(data: address, size: 200, backgroundColor: Colors.white),
              ),
            ),
            const SizedBox(height: AuroraSpacing.md),
            SelectableText(address, style: AuroraTypography.tabularFigures(AuroraTypography.labelMonoMd)),
            if (isUnencrypted(address)) ...<Widget>[
              const SizedBox(height: AuroraSpacing.sm),
              Text(
                "This address is not encrypted — use it only on a network you trust.",
                textAlign: TextAlign.center,
                style: AuroraTypography.bodySm.copyWith(color: context.statusWarning),
              ),
            ],
            const SizedBox(height: AuroraSpacing.md),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: address));
                if (!sheetContext.mounted) return;
                ScaffoldMessenger.of(sheetContext).showSnackBar(const SnackBar(content: Text("Address copied")));
              },
              icon: const Icon(Icons.copy),
              label: const Text("Copy address"),
            ),
          ],
        ),
      ),
    ),
  );
}
