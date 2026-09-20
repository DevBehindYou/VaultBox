import "package:flutter/cupertino.dart" show CupertinoPageTransitionsBuilder;
import "package:flutter/material.dart";

import "aurora_colors.dart";
import "aurora_context.dart";
import "aurora_spacing.dart";
import "aurora_typography.dart";

/// Builds the app's light/dark [ThemeData] from Aurora Glass tokens.
///
/// Elevation policy follows DESIGN.md: no dark drop shadows for standard
/// cards — a crisp 1.5px border stands in for elevation (`cardTheme` below).
/// The Aurora gradient itself is not a [ThemeData] concept (Flutter buttons
/// don't support gradient fills natively) — see `widgets/aurora_button.dart`
/// (Phase 1 UI) for the gradient primary button built on top of this theme.
abstract final class AuroraTheme {
  static ThemeData light({AuroraStyle style = AuroraStyle.standard, VisualDensity density = VisualDensity.standard}) {
    final ColorScheme scheme = const ColorScheme.light().copyWith(
      surface: AuroraColors.surface,
      onSurface: AuroraColors.onSurface,
      surfaceContainerLowest: AuroraColors.surfaceContainerLowest,
      surfaceContainerLow: AuroraColors.surfaceContainerLow,
      surfaceContainer: AuroraColors.surfaceContainer,
      surfaceContainerHigh: AuroraColors.surfaceContainerHigh,
      surfaceContainerHighest: AuroraColors.surfaceContainerHighest,
      outline: AuroraColors.outline,
      outlineVariant: AuroraColors.outlineVariant,
      primary: AuroraColors.primary,
      onPrimary: AuroraColors.onPrimary,
      primaryContainer: AuroraColors.primaryContainer,
      onPrimaryContainer: AuroraColors.onPrimaryContainer,
      secondary: AuroraColors.secondary,
      onSecondary: AuroraColors.onSecondary,
      tertiary: AuroraColors.tertiary,
      onTertiary: AuroraColors.onTertiary,
      error: AuroraColors.error,
      onError: AuroraColors.onError,
      errorContainer: AuroraColors.errorContainer,
      onErrorContainer: AuroraColors.onErrorContainer,
    );
    return _base(scheme, brightness: Brightness.light, style: style, density: density);
  }

  static ThemeData dark({AuroraStyle style = AuroraStyle.standard, VisualDensity density = VisualDensity.standard}) {
    final ColorScheme scheme = const ColorScheme.dark().copyWith(
      surface: AuroraColorsDark.surface,
      onSurface: AuroraColorsDark.onSurface,
      surfaceContainerLowest: AuroraColorsDark.surfaceContainerLowest,
      surfaceContainerLow: AuroraColorsDark.surfaceContainerLow,
      surfaceContainer: AuroraColorsDark.surfaceContainer,
      surfaceContainerHigh: AuroraColorsDark.surfaceContainerHigh,
      surfaceContainerHighest: AuroraColorsDark.surfaceContainerHighest,
      outline: AuroraColorsDark.outline,
      outlineVariant: AuroraColorsDark.outlineVariant,
      primary: AuroraColorsDark.primary,
      onPrimary: AuroraColorsDark.onPrimary,
      primaryContainer: AuroraColorsDark.primaryContainer,
      onPrimaryContainer: AuroraColorsDark.onPrimaryContainer,
      error: AuroraColors.error,
      onError: AuroraColors.onError,
    );
    return _base(scheme, brightness: Brightness.dark, style: style, density: density);
  }

  static ThemeData _base(
    ColorScheme scheme, {
    required Brightness brightness,
    required AuroraStyle style,
    required VisualDensity density,
  }) {
    final bool isDark = brightness == Brightness.dark;
    final Color borderDefault =
        isDark ? AuroraColorsDark.borderDefault : AuroraColors.borderDefault;
    final Color inkPrimary =
        isDark ? AuroraColorsDark.inkPrimary : AuroraColors.inkPrimary;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      visualDensity: density,
      extensions: <ThemeExtension<dynamic>>[style],
      // The mockups sit white cards on a warm grey page; dark keeps its own page.
      scaffoldBackgroundColor: isDark ? scheme.surface : scheme.surfaceContainer,
      fontFamily: AuroraFonts.body,
      textTheme: TextTheme(
        displayLarge: AuroraTypography.displayXl.copyWith(color: scheme.onSurface),
        headlineLarge: AuroraTypography.headlineLg.copyWith(color: scheme.onSurface),
        headlineMedium: AuroraTypography.headlineMd.copyWith(color: scheme.onSurface),
        headlineSmall: AuroraTypography.headlineSm.copyWith(color: scheme.onSurface),
        bodyLarge: AuroraTypography.bodyLg.copyWith(color: scheme.onSurface),
        bodyMedium: AuroraTypography.bodyMd.copyWith(color: scheme.onSurface),
        bodySmall: AuroraTypography.bodySm.copyWith(
          color: isDark ? AuroraColorsDark.inkSecondary : AuroraColors.inkSecondary,
        ),
        labelLarge: AuroraTypography.labelLg.copyWith(color: scheme.onSurface),
      ),
      // Structural Tier: flat #FFFFFF card + 1.5px border, zero shadow.
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLowest,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AuroraRadii.mdAll,
          side: BorderSide(color: borderDefault, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        side: BorderSide(color: borderDefault, width: 1.5),
        labelStyle: AuroraTypography.labelMonoMd.copyWith(color: scheme.onSurface),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        shape: const StadiumBorder(),
      ),
      // Aurora Primary Button visual baseline (flat fallback — gradient fill
      // is applied by AuroraPrimaryButton, not by ElevatedButtonTheme, since
      // Material buttons don't support gradient backgrounds directly).
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AuroraColors.auroraMid,
          foregroundColor: AuroraColors.inkPrimary,
          minimumSize: const Size.fromHeight(AuroraSpacing.minTouchTarget),
          shape: RoundedRectangleBorder(
            borderRadius: AuroraRadii.pillAll,
            side: const BorderSide(color: AuroraColors.borderStrong, width: 1.5),
          ),
          textStyle: AuroraTypography.labelLg.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: inkPrimary,
          minimumSize: const Size.fromHeight(AuroraSpacing.minTouchTarget),
          side: BorderSide(color: inkPrimary, width: 1.5),
          shape: const RoundedRectangleBorder(borderRadius: AuroraRadii.pillAll),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: AuroraRadii.standardAll,
          borderSide: BorderSide(color: borderDefault, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AuroraRadii.standardAll,
          borderSide: BorderSide(color: inkPrimary, width: 1.5),
        ),
      ),
      dividerTheme: DividerThemeData(color: borderDefault, thickness: 1),
      // Respect Reduce Motion (kickoff §14/§55) — callers should also check
      // MediaQuery.disableAnimations before playing the dock lens / hero
      // transitions; this keeps default page transitions restrained.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
