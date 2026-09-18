import "package:flutter/widgets.dart";

/// Aurora Glass typography tokens, transcribed from `aurora_glass/DESIGN.md`.
///
/// Three deliberate families per the design system:
/// - **Epilogue** — expressive display/headline type (personality, warmth).
/// - **Inter** — workhorse UI/body text (filenames, forms, settings, dialogs).
/// - **JetBrains Mono** — hardware/network telemetry (IPs, hashes, ports,
///   throughput). Numeric fields in this family must use tabular figures so
///   live-updating numbers don't jitter (DESIGN.md "Responsive Scaling").
///
/// Font family strings match what a real build would register via
/// `google_fonts` or bundled font assets in `pubspec.yaml`; wiring the actual
/// font files/package is a Phase 0 follow-up once the toolchain can fetch
/// packages (see docs/IMPLEMENTATION_PLAN.md §A) — until then these fall back
/// to the platform default with the right metrics, which is a safe default.
abstract final class AuroraFonts {
  static const String display = "Epilogue";
  static const String body = "Inter";
  static const String mono = "JetBrains Mono";
  static const String handwritten = "Patrick Hand";
}

abstract final class AuroraTypography {
  static const TextStyle displayXl = TextStyle(
    fontFamily: AuroraFonts.display,
    fontSize: 36,
    fontWeight: FontWeight.w700,
    height: 44 / 36,
    letterSpacing: -0.02 * 36,
  );

  static const TextStyle displayXlMobile = TextStyle(
    fontFamily: AuroraFonts.display,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    height: 38 / 30,
    letterSpacing: -0.02 * 30,
  );

  static const TextStyle headlineLg = TextStyle(
    fontFamily: AuroraFonts.display,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 36 / 28,
    letterSpacing: -0.01 * 28,
  );

  static const TextStyle headlineMd = TextStyle(
    fontFamily: AuroraFonts.display,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    height: 30 / 22,
  );

  static const TextStyle headlineSm = TextStyle(
    fontFamily: AuroraFonts.display,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 24 / 18,
  );

  static const TextStyle bodyLg = TextStyle(
    fontFamily: AuroraFonts.body,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 24 / 16,
  );

  static const TextStyle bodyMd = TextStyle(
    fontFamily: AuroraFonts.body,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 20 / 14,
  );

  static const TextStyle bodySm = TextStyle(
    fontFamily: AuroraFonts.body,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 18 / 12,
  );

  static const TextStyle labelLg = TextStyle(
    fontFamily: AuroraFonts.body,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 20 / 14,
  );

  /// Technical/telemetry label — IPs, ports, protocol chips. Always pair with
  /// [tabularFigures] when the content includes live-updating numbers.
  static const TextStyle labelMonoMd = TextStyle(
    fontFamily: AuroraFonts.mono,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 16 / 12,
  );

  static const TextStyle labelMonoSm = TextStyle(
    fontFamily: AuroraFonts.mono,
    fontSize: 10,
    fontWeight: FontWeight.w500,
    height: 14 / 10,
    letterSpacing: 0.02 * 10,
  );

  /// Applies `font-variant-numeric: tabular-nums` equivalent so throughput /
  /// ETA / byte counters don't visually jitter while streaming updates land.
  static TextStyle tabularFigures(TextStyle base) {
    return base.copyWith(
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
  }
}
