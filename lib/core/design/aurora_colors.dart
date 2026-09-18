import "package:flutter/painting.dart";

/// Aurora Glass color tokens, transcribed verbatim from
/// `stitch_full_app_ui_ux_design/aurora_glass/DESIGN.md`.
///
/// These are raw token values, not a [ThemeData] — see `aurora_theme.dart` for
/// how they're wired into light/dark [ColorScheme]s. Widgets should reach for
/// theme colors (`Theme.of(context).colorScheme...`) or [AuroraTheme] extension
/// getters rather than these constants directly, so dark mode stays correct.
abstract final class AuroraColors {
  // --- Material-ish base scale (light) ---
  static const Color surface = Color(0xFFFBF9F4);
  static const Color surfaceDim = Color(0xFFDCDAD5);
  static const Color surfaceBright = Color(0xFFFBF9F4);
  static const Color surfaceContainerLowest = Color(0xFFFFFFFF);
  static const Color surfaceContainerLow = Color(0xFFF5F3EE);
  static const Color surfaceContainer = Color(0xFFF0EEE9);
  static const Color surfaceContainerHigh = Color(0xFFEAE8E3);
  static const Color surfaceContainerHighest = Color(0xFFE4E2DD);
  static const Color onSurface = Color(0xFF1B1C19);
  static const Color onSurfaceVariant = Color(0xFF484551);
  static const Color inverseSurface = Color(0xFF30312D);
  static const Color inverseOnSurface = Color(0xFFF3F1EB);
  static const Color outline = Color(0xFF797582);
  static const Color outlineVariant = Color(0xFFC9C4D2);

  static const Color surfaceTint = Color(0xFF5F53A4);
  static const Color primary = Color(0xFF5C50A1);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color primaryContainer = Color(0xFF7569BC);
  static const Color onPrimaryContainer = Color(0xFFFFFBFF);
  static const Color inversePrimary = Color(0xFFC8BFFF);

  static const Color secondary = Color(0xFF005EB4);
  static const Color onSecondary = Color(0xFFFFFFFF);
  static const Color secondaryContainer = Color(0xFF5A9FFF);
  static const Color onSecondaryContainer = Color(0xFF00356A);

  static const Color tertiary = Color(0xFF864866);
  static const Color onTertiary = Color(0xFFFFFFFF);
  static const Color tertiaryContainer = Color(0xFFA2607F);
  static const Color onTertiaryContainer = Color(0xFFFFFBFF);

  static const Color error = Color(0xFFBA1A1A);
  static const Color onError = Color(0xFFFFFFFF);
  static const Color errorContainer = Color(0xFFFFDAD6);
  static const Color onErrorContainer = Color(0xFF93000A);

  static const Color background = Color(0xFFFBF9F4);
  static const Color onBackground = Color(0xFF1B1C19);
  static const Color surfaceVariant = Color(0xFFE4E2DD);

  // --- "Ink" hierarchy (used for borders/text on structural cards) ---
  static const Color surfacePrimary = Color(0xFFFFFFFF);
  static const Color surfaceSecondary = Color(0xFFFAFAFA);
  static const Color surfaceTertiary = Color(0xFFF7F7F5);
  static const Color inkPrimary = Color(0xFF1A1A1A);
  static const Color inkSecondary = Color(0xFF666666);
  static const Color inkTertiary = Color(0xFF8A8A8A);
  static const Color inkDisabled = Color(0xFFA5A5A5);
  static const Color borderStrong = Color(0xFF1A1A1A);
  static const Color borderDefault = Color(0xFFDCDCDC);
  static const Color borderMuted = Color(0xFFE8E8E8);

  // --- Selection (file multi-select, distinct from brand actions) ---
  static const Color selectionBlue = Color(0xFF2A78D6);
  static const Color selectionSoft = Color(0xFFEEF3FB);

  // --- Aurora gradient stops ---
  static const Color auroraLavender = Color(0xFF8F83D8);
  static const Color auroraMid = Color(0xFFB58FD0);
  static const Color auroraPink = Color(0xFFD98FB0);
  static const Color auroraSoftLavender = Color(0xFFCFC8EF);
  static const Color auroraSoftPink = Color(0xFFEEC9D6);

  // --- Semantic status (always paired with a glyph, never color-only — NFR-ACC-002) ---
  static const Color statusSuccess = Color(0xFF3A7A4A);
  static const Color statusSuccessBorder = Color(0xFFB0CDB4);
  static const Color statusWarning = Color(0xFF8A6A2A);
  static const Color statusWarningBorder = Color(0xFFDCD0B0);
  static const Color statusDanger = Color(0xFFA34A4A);
  static const Color statusDangerBorder = Color(0xFFC98A8A);
  static const Color statusDangerSurface = Color(0xFFFDF6F6);

  /// Primary Aurora gradient — hero server indicators, primary buttons,
  /// selection pills, storage meters. 135° per DESIGN.md.
  static const LinearGradient primaryAurora = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[auroraLavender, auroraMid, auroraPink],
  );

  /// Soft Aurora gradient — ambient glows, onboarding spotlights, empty states.
  static const LinearGradient softAurora = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[auroraSoftLavender, auroraSoftPink],
  );
}

/// Dark-theme counterparts. The design spec only fully documents light mode;
/// these follow the same ink-hierarchy logic inverted, and NFR requires both
/// themes be complete (kickoff §54) — revisit against real dark mockups before
/// Phase 10 (production hardening) sign-off.
abstract final class AuroraColorsDark {
  static const Color surface = Color(0xFF15151A);
  static const Color surfaceContainerLowest = Color(0xFF0F0F13);
  static const Color surfaceContainerLow = Color(0xFF1A1A20);
  static const Color surfaceContainer = Color(0xFF202027);
  static const Color surfaceContainerHigh = Color(0xFF2A2A32);
  static const Color surfaceContainerHighest = Color(0xFF34343D);
  static const Color onSurface = Color(0xFFEDEBF3);
  static const Color onSurfaceVariant = Color(0xFFC9C4D2);
  static const Color outline = Color(0xFF938F9C);
  static const Color outlineVariant = Color(0xFF484551);

  static const Color primary = Color(0xFFC8BFFF);
  static const Color onPrimary = Color(0xFF322670);
  static const Color primaryContainer = Color(0xFF473A8A);
  static const Color onPrimaryContainer = Color(0xFFE5DEFF);

  static const Color inkPrimary = Color(0xFFF3F1EB);
  static const Color inkSecondary = Color(0xFFB0AFB4);
  static const Color inkTertiary = Color(0xFF8A8A8A);
  static const Color borderStrong = Color(0xFFF3F1EB);
  static const Color borderDefault = Color(0xFF3A3A42);
  static const Color borderMuted = Color(0xFF2A2A32);

  static const Color statusSuccess = Color(0xFF7CC493);
  static const Color statusSuccessBorder = Color(0xFF3A7A4A);
  static const Color statusWarning = Color(0xFFE0C177);
  static const Color statusWarningBorder = Color(0xFF8A6A2A);
  static const Color statusDanger = Color(0xFFE59A9A);
  static const Color statusDangerBorder = Color(0xFFA34A4A);
  static const Color statusDangerSurface = Color(0xFF2A1717);
}
