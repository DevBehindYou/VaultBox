import "package:flutter/material.dart";
import "package:go_router/go_router.dart";

import "../core/design/aurora_colors.dart";
import "../core/design/aurora_context.dart";
import "../core/design/aurora_spacing.dart";
import "../core/design/aurora_typography.dart";
import "app_header.dart";

/// The five-destination shell with the Aurora floating nav dock.
///
/// The dock's moving "glass lens" is an intentional signature element, but
/// kickoff §14/§55 require it to respect Reduce Motion — so the indicator
/// animation duration collapses to zero when `MediaQuery.disableAnimations`
/// is set rather than being unconditionally animated.
class ShellScaffold extends StatelessWidget {
  const ShellScaffold({required this.shell, super.key});

  final StatefulNavigationShell shell;

  // Settings is a sixth branch (see router.dart) reached from AppHeader's
  // tune icon, not from the dock — kickoff's five permanent destinations
  // stayed four-wide-plus-a-gear once Settings had a real header entry
  // point, so the dock no longer needs to spend a slot on it too. Share took
  // the same route out (reached from Home, Files and Settings instead); its
  // dock slot now shows Server (Protocols & Network) directly, since that
  // screen — not Home's status card — is where every protocol's own on/off
  // switch and its port live.
  static const List<_Destination> _destinations = <_Destination>[
    _Destination(icon: Icons.dns_outlined, label: "Home"),
    _Destination(icon: Icons.folder_outlined, label: "Files"),
    _Destination(icon: Icons.router_outlined, label: "Server"),
    _Destination(icon: Icons.swap_vert, label: "Activity"),
  ];

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      // The header takes the status-bar inset itself, so what sits under it
      // must not add the same inset again.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            // Settings (branch index 4) has no dock item any more, so its
            // index falls outside _destinations — fall back to a fixed label
            // rather than indexing out of range.
            AppHeader(
              subtitle: shell.currentIndex < _destinations.length
                  ? _destinations[shell.currentIndex].label
                  : "Settings",
            ),
            Expanded(
              child: MediaQuery.removePadding(context: context, removeTop: true, child: shell),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          height: AuroraSpacing.dockHeight,
          margin: const EdgeInsets.fromLTRB(
            AuroraSpacing.marginCompact,
            0,
            AuroraSpacing.marginCompact,
            AuroraSpacing.dockBottomMargin,
          ),
          decoration: BoxDecoration(
            color: context.cardColor,
            borderRadius: AuroraRadii.pillAll,
            border: isDark ? Border.all(color: context.borderDefault) : null,
            boxShadow: isDark
                ? null
                : const <BoxShadow>[BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2))],
          ),
          child: Stack(
            children: <Widget>[
              // The lens itself: one pill that SLIDES to the selected index,
              // behind the (static-position) icons/labels — rather than each
              // item independently cross-fading its own background in place,
              // which is what was here before despite this file's own doc
              // comment already calling it a "moving" lens.
              AnimatedAlign(
                duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment(
                  _destinations.length < 2
                      ? 0
                      : -1 + 2 * shell.currentIndex / (_destinations.length - 1),
                  0,
                ),
                child: FractionallySizedBox(
                  widthFactor: 1 / _destinations.length,
                  child: Container(
                    margin: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      gradient: AuroraStyle.of(context).gradients ? AuroraColors.primaryAurora : null,
                      color: AuroraStyle.of(context).gradients ? null : AuroraColors.auroraSoftLavender,
                      borderRadius: AuroraRadii.pillAll,
                    ),
                  ),
                ),
              ),
              Row(
                children: <Widget>[
                  for (int index = 0; index < _destinations.length; index++)
                    Expanded(
                      child: _DockItem(
                        destination: _destinations[index],
                        selected: shell.currentIndex == index,
                        reduceMotion: reduceMotion,
                        // initialLocation: true re-navigates to the branch root
                        // when the already-selected tab is tapped — the
                        // standard "tap current tab to go home" behaviour.
                        onTap: () => shell.goBranch(
                          index,
                          initialLocation: index == shell.currentIndex,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Destination {
  const _Destination({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.destination,
    required this.selected,
    required this.reduceMotion,
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final bool reduceMotion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The sliding lens (in ShellScaffold, behind this Row) now carries the
    // background — this item only animates its own icon/label color+weight
    // as the lens passes under it.
    final Duration duration = reduceMotion ? Duration.zero : const Duration(milliseconds: 180);
    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: AuroraRadii.pillAll,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              // Icon doesn't read DefaultTextStyle (only IconTheme), so
              // AnimatedDefaultTextStyle can't animate its color the way it
              // does the label below — TweenAnimationBuilder animates the
              // Color directly instead.
              TweenAnimationBuilder<Color?>(
                duration: duration,
                curve: Curves.easeOutCubic,
                tween: ColorTween(end: selected ? AuroraColors.inkPrimary : context.inkSecondary),
                builder: (BuildContext context, Color? color, Widget? child) =>
                    Icon(destination.icon, size: 20, color: color),
              ),
              const SizedBox(height: 2),
              AnimatedDefaultTextStyle(
                duration: duration,
                curve: Curves.easeOutCubic,
                style: AuroraTypography.bodySm.copyWith(
                  color: selected ? AuroraColors.inkPrimary : context.inkSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
                child: Text(
                  destination.label,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
