import "package:flutter/material.dart";
import "package:go_router/go_router.dart";

import "../core/design/aurora_colors.dart";
import "../core/design/aurora_spacing.dart";
import "../core/design/aurora_typography.dart";

/// The five-destination shell with the Aurora floating nav dock.
///
/// The dock's moving "glass lens" is an intentional signature element, but
/// kickoff §14/§55 require it to respect Reduce Motion — so the indicator
/// animation duration collapses to zero when `MediaQuery.disableAnimations`
/// is set rather than being unconditionally animated.
class ShellScaffold extends StatelessWidget {
  const ShellScaffold({required this.shell, super.key});

  final StatefulNavigationShell shell;

  static const List<_Destination> _destinations = <_Destination>[
    _Destination(icon: Icons.dns_outlined, label: "Home"),
    _Destination(icon: Icons.folder_outlined, label: "Files"),
    _Destination(icon: Icons.share_outlined, label: "Share"),
    _Destination(icon: Icons.swap_vert, label: "Activity"),
    _Destination(icon: Icons.tune, label: "Settings"),
  ];

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: shell,
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
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            borderRadius: AuroraRadii.pillAll,
            border: Border.all(
              color: isDark ? AuroraColorsDark.borderDefault : AuroraColors.borderDefault,
              width: 1.5,
            ),
          ),
          child: Row(
            children: <Widget>[
              for (int index = 0; index < _destinations.length; index++)
                Expanded(
                  child: _DockItem(
                    destination: _destinations[index],
                    selected: shell.currentIndex == index,
                    reduceMotion: reduceMotion,
                    // initialLocation: true re-navigates to the branch root when
                    // the already-selected tab is tapped — the standard
                    // "tap current tab to go home" behaviour.
                    onTap: () => shell.goBranch(
                      index,
                      initialLocation: index == shell.currentIndex,
                    ),
                  ),
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
    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: AuroraRadii.pillAll,
        child: AnimatedContainer(
          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            gradient: selected ? AuroraColors.primaryAurora : null,
            borderRadius: AuroraRadii.pillAll,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                destination.icon,
                size: 20,
                color: selected ? AuroraColors.inkPrimary : AuroraColors.inkSecondary,
              ),
              const SizedBox(height: 2),
              Text(
                destination.label,
                style: AuroraTypography.bodySm.copyWith(
                  color: selected ? AuroraColors.inkPrimary : AuroraColors.inkSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
