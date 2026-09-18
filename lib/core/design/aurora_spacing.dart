import "package:flutter/widgets.dart";

/// Spacing, radius and breakpoint tokens from `aurora_glass/DESIGN.md`.
///
/// Layout is built on a 4dp base grid (design system's own description). Radii
/// follow the documented small/medium/large/pill scale.
abstract final class AuroraSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;

  /// Screen edge margin, compact (phone) breakpoint.
  static const double marginCompact = 16;

  /// Screen edge margin, medium (tablet/foldable) breakpoint.
  static const double marginMedium = 20;

  /// Screen edge margin, expanded (desktop/DeX) breakpoint.
  static const double marginExpanded = 24;

  /// Standard card internal padding, compact breakpoint.
  static const double cardPaddingCompact = 12;

  /// Floating dock height (compacts to [dockHeightCompact] while fast-scrolling
  /// per DESIGN.md — implement that compaction in the dock widget itself).
  static const double dockHeight = 74;
  static const double dockHeightCompact = 58;
  static const double dockBottomMargin = 16;

  /// Content lists must reserve this much bottom padding so the floating dock
  /// never occludes the last scrollable row (DESIGN.md "Dock Offsets").
  static const double dockScrollClearance =
      dockHeight + dockBottomMargin + 16;

  /// Minimum interactive hit target — NFR-ACC-001.
  static const double minTouchTarget = 48;
}

abstract final class AuroraRadii {
  static const Radius sm = Radius.circular(4);
  static const Radius standard = Radius.circular(8);
  static const Radius md = Radius.circular(12);
  static const Radius lg = Radius.circular(16);
  static const Radius xl = Radius.circular(24);
  static const Radius pill = Radius.circular(9999);

  static const BorderRadius smAll = BorderRadius.all(sm);
  static const BorderRadius standardAll = BorderRadius.all(standard);
  static const BorderRadius mdAll = BorderRadius.all(md);
  static const BorderRadius lgAll = BorderRadius.all(lg);
  static const BorderRadius xlAll = BorderRadius.all(xl);
  static const BorderRadius pillAll = BorderRadius.all(pill);
}

/// Responsive breakpoints per DESIGN.md ("Grid & Breakpoints").
enum AuroraBreakpoint { compact, medium, expanded }

abstract final class AuroraBreakpoints {
  static const double mediumMinWidth = 600;
  static const double expandedMinWidth = 840;
  static const double maxContentWidth = 1280;

  static AuroraBreakpoint of(double width) {
    if (width >= expandedMinWidth) return AuroraBreakpoint.expanded;
    if (width >= mediumMinWidth) return AuroraBreakpoint.medium;
    return AuroraBreakpoint.compact;
  }
}
