import "package:flutter/material.dart";

import "aurora_colors.dart";
import "aurora_context.dart";
import "aurora_spacing.dart";
import "aurora_typography.dart";

/// The card the mockups use for almost everything: a white (light) or
/// near-black (dark) surface with rounded corners. Light cards lift with a
/// whisper of shadow; dark cards get a thin border instead, since a shadow
/// doesn't show on a dark page.
class AuroraCard extends StatelessWidget {
  const AuroraCard({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(AuroraSpacing.md),
    this.onTap,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final bool dark = context.isDarkTheme;
    final Color? accent = borderColor;

    final Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: AuroraRadii.lgAll,
        border: accent != null
            ? Border.all(color: accent, width: 1.5)
            : (dark ? Border.all(color: context.borderDefault) : null),
        boxShadow: dark
            ? null
            : const <BoxShadow>[BoxShadow(color: Color(0x0F000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: child,
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AuroraRadii.lgAll,
        child: content,
      ),
    );
  }
}

/// Primary action button carrying the Aurora gradient. Material's button
/// themes can't express a gradient fill, so this wraps an [InkWell] over a
/// gradient [Container] rather than fighting [ElevatedButton].
class AuroraPrimaryButton extends StatelessWidget {
  const AuroraPrimaryButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.icon,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    final bool gradient = AuroraStyle.of(context).gradients;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AuroraRadii.pillAll,
          child: Container(
            width: expand ? double.infinity : null,
            constraints: const BoxConstraints(minHeight: AuroraSpacing.minTouchTarget),
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              gradient: gradient ? AuroraColors.primaryAurora : null,
              color: gradient ? null : AuroraColors.auroraMid,
              borderRadius: AuroraRadii.pillAll,
              boxShadow: context.isDarkTheme
                  ? null
                  : const <BoxShadow>[BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 1))],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 18, color: AuroraColors.inkPrimary),
                  const SizedBox(width: AuroraSpacing.sm),
                ],
                Text(
                  label,
                  style: AuroraTypography.labelLg.copyWith(
                    color: AuroraColors.inkPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum AuroraStatus { live, warning, danger, idle }

/// Status chip. Per NFR-ACC-002 status is **never** carried by colour alone —
/// every variant pairs its colour with a distinct glyph and a text label, so
/// it still reads correctly in greyscale or with colour-vision deficiency.
class AuroraStatusChip extends StatelessWidget {
  const AuroraStatusChip({
    required this.label,
    required this.status,
    super.key,
    this.detail,
  });

  final String label;
  final AuroraStatus status;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    final (Color foreground, Color border, IconData glyph) = switch (status) {
      AuroraStatus.live => (
        isDark ? AuroraColorsDark.statusSuccess : AuroraColors.statusSuccess,
        isDark ? AuroraColorsDark.statusSuccessBorder : AuroraColors.statusSuccessBorder,
        Icons.check_circle_outline,
      ),
      AuroraStatus.warning => (
        isDark ? AuroraColorsDark.statusWarning : AuroraColors.statusWarning,
        isDark ? AuroraColorsDark.statusWarningBorder : AuroraColors.statusWarningBorder,
        Icons.error_outline,
      ),
      AuroraStatus.danger => (
        isDark ? AuroraColorsDark.statusDanger : AuroraColors.statusDanger,
        isDark ? AuroraColorsDark.statusDangerBorder : AuroraColors.statusDangerBorder,
        Icons.cancel_outlined,
      ),
      AuroraStatus.idle => (
        isDark ? AuroraColorsDark.inkTertiary : AuroraColors.inkTertiary,
        isDark ? AuroraColorsDark.borderDefault : AuroraColors.borderDefault,
        Icons.radio_button_unchecked,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: AuroraRadii.pillAll,
        border: Border.all(color: border, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(glyph, size: 12, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: AuroraTypography.labelMonoMd.copyWith(color: foreground),
          ),
          if (detail != null) ...<Widget>[
            const SizedBox(width: 6),
            Text(
              detail!,
              style: AuroraTypography.tabularFigures(
                AuroraTypography.labelMonoMd,
              ).copyWith(
                color: isDark ? AuroraColorsDark.inkTertiary : AuroraColors.inkTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Inline banner for actionable problems. Deliberately not a dialog: doc §73
/// says security/error messaging appears when it's actionable, not as a modal
/// interruption.
class AuroraInlineBanner extends StatelessWidget {
  const AuroraInlineBanner({
    required this.message,
    required this.status,
    super.key,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.technicalDetail,
  });

  final String message;
  final AuroraStatus status;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  /// Shown only behind an explicit disclosure — never as the headline
  /// (kickoff §71).
  final String? technicalDetail;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color border = switch (status) {
      AuroraStatus.danger =>
        isDark ? AuroraColorsDark.statusDangerBorder : AuroraColors.statusDangerBorder,
      AuroraStatus.warning =>
        isDark ? AuroraColorsDark.statusWarningBorder : AuroraColors.statusWarningBorder,
      _ => isDark ? AuroraColorsDark.borderDefault : AuroraColors.borderDefault,
    };

    return AuroraCard(
      borderColor: border,
      padding: const EdgeInsets.all(AuroraSpacing.cardPaddingCompact),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                status == AuroraStatus.danger ? Icons.cancel_outlined : Icons.error_outline,
                size: 18,
                color: border,
              ),
              const SizedBox(width: AuroraSpacing.sm),
              Expanded(
                child: Text(message, style: AuroraTypography.bodyMd),
              ),
              if (onDismiss != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onDismiss,
                  tooltip: "Dismiss",
                  constraints: const BoxConstraints(
                    minWidth: AuroraSpacing.minTouchTarget,
                    minHeight: AuroraSpacing.minTouchTarget,
                  ),
                ),
            ],
          ),
          if (technicalDetail != null)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              // ExpansionTile paints on the nearest Material; the card's coloured
              // DecoratedBox would hide its ink and trips a framework assertion
              // (found by Home's failed-server widget test). Give it its own.
              child: Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text("Technical details", style: AuroraTypography.bodySm),
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        technicalDetail!,
                        style: AuroraTypography.labelMonoSm,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (actionLabel != null && onAction != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ),
        ],
      ),
    );
  }
}
