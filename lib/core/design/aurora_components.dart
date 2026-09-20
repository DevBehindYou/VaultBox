import "package:flutter/material.dart";

import "aurora_colors.dart";
import "aurora_context.dart";
import "aurora_spacing.dart";
import "aurora_typography.dart";
import "aurora_widgets.dart";

/// A protocol pill for the row under the server card: a dot that says whether
/// it is listening, its name and its port. The state is also in the semantics
/// label, so it doesn't rest on the dot's colour alone.
class AuroraProtocolChip extends StatelessWidget {
  const AuroraProtocolChip({required this.label, required this.active, this.detail, super.key});

  final String label;
  final String? detail;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final String? port = detail;
    return Semantics(
      label: "$label${port == null ? "" : " $port"}, ${active ? "listening" : "off"}",
      child: ExcludeSemantics(
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: active ? context.cardColor : context.cardColor.withValues(alpha: 0.7),
            borderRadius: AuroraRadii.pillAll,
            border: context.isDarkTheme ? Border.all(color: context.borderDefault) : null,
            boxShadow: context.isDarkTheme
                ? null
                : const <BoxShadow>[BoxShadow(color: Color(0x0F000000), blurRadius: 4, offset: Offset(0, 1))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? context.statusSuccess : context.inkDisabled,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: context.mono(color: active ? context.inkPrimary : context.inkSecondary, weight: FontWeight.w600),
              ),
              if (port != null) ...<Widget>[
                const SizedBox(width: 6),
                Text(port, style: context.mono(color: active ? context.inkTertiary : context.inkDisabled, size: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small at-a-glance tile: a label, one number or phrase, one line of context.
class AuroraMetricCard extends StatelessWidget {
  const AuroraMetricCard({
    required this.title,
    required this.icon,
    required this.value,
    this.caption,
    this.onTap,
    super.key,
  });

  final String title;
  final IconData icon;
  final String value;
  final String? caption;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final String? note = caption;
    return AuroraCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: context.mono(size: 10, color: context.inkSecondary).copyWith(letterSpacing: 0.6),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(icon, size: 18, color: context.scheme.primary),
            ],
          ),
          const SizedBox(height: AuroraSpacing.sm),
          Text(
            value,
            style: AuroraTypography.headlineSm.copyWith(color: context.inkPrimary, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (note != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(note, style: context.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }
}

/// A heading between groups of cards: the friendly title and, on the right,
/// a small technical label or an action.
class AuroraSectionHeader extends StatelessWidget {
  const AuroraSectionHeader({required this.title, this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, AuroraSpacing.md, 4, AuroraSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(child: Text(title, style: context.brand(20))),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// The header of a screen you reach from Settings: a back pill, the title in the
/// friendly voice, and one line saying what the screen is for.
class AuroraSubHeader extends StatelessWidget {
  const AuroraSubHeader({required this.title, this.subtitle, this.parentLabel = "Settings", this.onBack, super.key});

  final String title;
  final String? subtitle;
  final String parentLabel;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final String? line = subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Semantics(
          button: true,
          label: "Back to $parentLabel",
          child: InkWell(
            onTap: () {
              final VoidCallback? back = onBack;
              if (back != null) {
                back();
              } else {
                Navigator.of(context).maybePop<void>();
              }
            },
            borderRadius: AuroraRadii.pillAll,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(color: context.cardColor, borderRadius: AuroraRadii.pillAll),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.arrow_back, size: 18, color: context.inkPrimary),
                  const SizedBox(width: 6),
                  ExcludeSemantics(child: Text(parentLabel, style: AuroraTypography.labelLg.copyWith(color: context.inkPrimary))),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AuroraSpacing.md),
        Text(title, style: context.brand(30)),
        if (line != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(line, style: context.bodySecondary),
        ],
        const SizedBox(height: AuroraSpacing.md),
      ],
    );
  }
}

/// One slice of a [AuroraStorageMeter].
final class MeterSegment {
  const MeterSegment({required this.label, required this.bytes, required this.color});

  final String label;
  final int bytes;
  final Color color;
}

/// A capacity bar cut into coloured slices, with a legend under it.
class AuroraStorageMeter extends StatelessWidget {
  const AuroraStorageMeter({required this.segments, required this.format, this.showLegend = true, super.key});

  final List<MeterSegment> segments;

  /// Turns a byte count into text for the legend ("18.2 GB").
  final String Function(int bytes) format;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final List<MeterSegment> shown = segments.where((MeterSegment s) => s.bytes > 0).toList();
    final int total = shown.fold<int>(0, (int sum, MeterSegment s) => sum + s.bytes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          height: 12,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.pillAll),
          child: total == 0
              ? const SizedBox.expand()
              : Row(
                  children: <Widget>[
                    for (int i = 0; i < shown.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: 2),
                      Expanded(
                        flex: ((shown[i].bytes / total) * 1000).round().clamp(1, 1000).toInt(),
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: shown[i].color, borderRadius: AuroraRadii.pillAll),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        if (showLegend) ...<Widget>[
          const SizedBox(height: AuroraSpacing.sm),
          Wrap(
            spacing: AuroraSpacing.md,
            runSpacing: AuroraSpacing.xs,
            children: <Widget>[
              for (final MeterSegment segment in segments)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: segment.color)),
                    const SizedBox(width: 6),
                    Text(segment.label, style: context.caption),
                    const SizedBox(width: 6),
                    Text(format(segment.bytes), style: context.mono(color: context.inkPrimary, weight: FontWeight.w600)),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Rows that sit together in one card, divided by hairlines.
class AuroraRowGroup extends StatelessWidget {
  const AuroraRowGroup({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AuroraCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: <Widget>[
          for (int i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0) Divider(height: 1, thickness: 1, indent: 16, endIndent: 16, color: context.borderMuted),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A row in a group: a tinted icon tile, a title, a line of explanation and a
/// chevron (or any [trailing] widget). Tap it to open what it names.
class AuroraSettingRow extends StatelessWidget {
  const AuroraSettingRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.danger = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final String? line = subtitle;
    final Color accent = danger ? context.statusDanger : context.inkPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: danger ? context.statusDangerSurface : context.panelColor,
                borderRadius: AuroraRadii.mdAll,
              ),
              child: Icon(icon, size: 22, color: danger ? context.statusDanger : context.scheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: AuroraTypography.bodyLg.copyWith(color: accent, fontWeight: FontWeight.w500)),
                  if (line != null) Text(line, style: context.caption),
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(Icons.chevron_right, color: context.inkTertiary),
          ],
        ),
      ),
    );
  }
}

/// A row with an on/off switch. With [onChanged] null the switch is dimmed, and
/// [subtitle] should say why.
class AuroraSwitchRow extends StatelessWidget {
  const AuroraSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    super.key,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final String? line = subtitle;
    final IconData? glyph = icon;
    return MergeSemantics(
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: <Widget>[
              if (glyph != null) ...<Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.mdAll),
                  child: Icon(glyph, size: 22, color: context.scheme.primary),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: AuroraTypography.bodyLg.copyWith(
                        color: onChanged == null ? context.inkSecondary : context.inkPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (line != null) Text(line, style: context.caption),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// The friendly empty state: a tinted icon, a short statement, one line of
/// help and (optionally) the one action that fixes it.
class AuroraEmptyState extends StatelessWidget {
  const AuroraEmptyState({required this.icon, required this.title, required this.message, this.action, super.key});

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return AuroraCard(
      padding: const EdgeInsets.all(AuroraSpacing.xl),
      child: Column(
        children: <Widget>[
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(shape: BoxShape.circle, gradient: AuroraColors.softAurora),
            child: Icon(icon, size: 28, color: AuroraColors.inkPrimary),
          ),
          const SizedBox(height: AuroraSpacing.md),
          Text(title, style: context.brand(22), textAlign: TextAlign.center),
          const SizedBox(height: AuroraSpacing.xs),
          Text(message, style: context.bodySecondary, textAlign: TextAlign.center),
          if (action != null) ...<Widget>[const SizedBox(height: AuroraSpacing.md), action!],
        ],
      ),
    );
  }
}
