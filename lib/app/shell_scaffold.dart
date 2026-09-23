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
      // The header takes the status-bar inset itself, so what sits under it
      // must not add the same inset again.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            AppHeader(subtitle: _destinations[shell.currentIndex].label),
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
            gradient: selected && AuroraStyle.of(context).gradients ? AuroraColors.primaryAurora : null,
            color: selected && !AuroraStyle.of(context).gradients ? AuroraColors.auroraSoftLavender : null,
            borderRadius: AuroraRadii.pillAll,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                destination.icon,
                size: 20,
                color: selected ? AuroraColors.inkPrimary : context.inkSecondary,
              ),
              const SizedBox(height: 2),
              Text(
                destination.label,
                style: AuroraTypography.bodySm.copyWith(
                  color: selected ? AuroraColors.inkPrimary : context.inkSecondary,
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
