import "package:flutter/material.dart";

import "aurora_colors.dart";
import "aurora_typography.dart";

/// Look-and-feel choices a person can make in Appearance. They travel with the
/// theme (as a [ThemeExtension]) so any widget can read them without a provider
/// — which also keeps widget tests free of a database.
@immutable
final class AuroraStyle extends ThemeExtension<AuroraStyle> {
  const AuroraStyle({this.handwrittenHeadlines = true, this.gradients = true});

  /// Patrick Hand for page and card titles; off gives a plain semibold sans.
  final bool handwrittenHeadlines;

  /// The lavender-to-pink accent on primary buttons and the dock's selection.
  final bool gradients;

  static const AuroraStyle standard = AuroraStyle();

  static AuroraStyle of(BuildContext context) => Theme.of(context).extension<AuroraStyle>() ?? standard;

  @override
  AuroraStyle copyWith({bool? handwrittenHeadlines, bool? gradients}) => AuroraStyle(
    handwrittenHeadlines: handwrittenHeadlines ?? this.handwrittenHeadlines,
    gradients: gradients ?? this.gradients,
  );

  @override
  AuroraStyle lerp(ThemeExtension<AuroraStyle>? other, double t) => other is AuroraStyle ? (t < 0.5 ? this : other) : this;
}

/// Theme-aware colours and text styles: the same call gives the right value in
/// light and dark, so screens never hard-code one theme's ink.
extension AuroraContext on BuildContext {
  bool get isDarkTheme => Theme.of(this).brightness == Brightness.dark;

  ColorScheme get scheme => Theme.of(this).colorScheme;

  Color get inkPrimary => isDarkTheme ? AuroraColorsDark.inkPrimary : AuroraColors.inkPrimary;
  Color get inkSecondary => isDarkTheme ? AuroraColorsDark.inkSecondary : AuroraColors.inkSecondary;
  Color get inkTertiary => isDarkTheme ? AuroraColorsDark.inkTertiary : AuroraColors.inkTertiary;
  Color get inkDisabled => isDarkTheme ? AuroraColorsDark.inkTertiary.withValues(alpha: 0.6) : AuroraColors.inkDisabled;

  Color get borderDefault => isDarkTheme ? AuroraColorsDark.borderDefault : AuroraColors.borderDefault;
  Color get borderMuted => isDarkTheme ? AuroraColorsDark.borderMuted : AuroraColors.borderMuted;

  Color get statusSuccess => isDarkTheme ? AuroraColorsDark.statusSuccess : AuroraColors.statusSuccess;
  Color get statusSuccessBorder => isDarkTheme ? AuroraColorsDark.statusSuccessBorder : AuroraColors.statusSuccessBorder;
  Color get statusWarning => isDarkTheme ? AuroraColorsDark.statusWarning : AuroraColors.statusWarning;
  Color get statusWarningBorder => isDarkTheme ? AuroraColorsDark.statusWarningBorder : AuroraColors.statusWarningBorder;
  Color get statusDanger => isDarkTheme ? AuroraColorsDark.statusDanger : AuroraColors.statusDanger;
  Color get statusDangerBorder => isDarkTheme ? AuroraColorsDark.statusDangerBorder : AuroraColors.statusDangerBorder;
  Color get statusDangerSurface => isDarkTheme ? AuroraColorsDark.statusDangerSurface : AuroraColors.statusDangerSurface;

  /// The white (light) / near-black (dark) surface of a card.
  Color get cardColor => scheme.surfaceContainerLowest;

  /// The slightly tinted panel inside a card (an address block, a metric).
  Color get panelColor => scheme.surfaceContainerLow;

  /// The chip / pill fill.
  Color get pillColor => scheme.surfaceContainerHigh;

  /// A heading in the design's friendly voice: Patrick Hand when that is on,
  /// a plain semibold sans otherwise.
  TextStyle brand(double size, {Color? color}) {
    final Color ink = color ?? inkPrimary;
    if (AuroraStyle.of(this).handwrittenHeadlines) {
      return TextStyle(fontFamily: AuroraFonts.handwritten, fontSize: size, height: 1.2, color: ink);
    }
    return TextStyle(fontSize: size - 2, fontWeight: FontWeight.w600, height: 1.25, color: ink);
  }

  /// Small technical text: addresses, ports, counts, protocol names.
  TextStyle mono({double size = 12, Color? color, FontWeight weight = FontWeight.w500}) => AuroraTypography.tabularFigures(
    TextStyle(
      fontFamily: AuroraFonts.mono,
      fontSize: size,
      fontWeight: weight,
      height: 1.35,
      color: color ?? inkSecondary,
    ),
  );

  TextStyle get body => AuroraTypography.bodyMd.copyWith(color: inkPrimary);
  TextStyle get bodySecondary => AuroraTypography.bodyMd.copyWith(color: inkSecondary);
  TextStyle get caption => AuroraTypography.bodySm.copyWith(color: inkSecondary);
}
