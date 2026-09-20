import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/preferences.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_components.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../domain/entities/app_preferences.dart";

/// Appearance & Display: light, dark or follow the phone; how headings look;
/// how much room things get. Every switch here changes something you can see
/// straight away.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPreferences prefs = ref.watch(preferencesProvider).value ?? const AppPreferences();
    final PreferencesNotifier notifier = ref.read(preferencesProvider.notifier);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AuroraSpacing.marginCompact,
          AuroraSpacing.sm,
          AuroraSpacing.marginCompact,
          AuroraSpacing.dockScrollClearance,
        ),
        children: <Widget>[
          const AuroraSubHeader(
            title: "Appearance & Display",
            subtitle: "Theme, headings and spacing. Changes apply at once.",
          ),
          Text("SURFACE THEME", style: context.mono(size: 11, color: context.inkSecondary).copyWith(letterSpacing: 0.8)),
          const SizedBox(height: AuroraSpacing.sm),
          Row(
            children: <Widget>[
              for (final ThemePreference option in ThemePreference.values) ...<Widget>[
                if (option != ThemePreference.system) const SizedBox(width: AuroraSpacing.sm),
                Expanded(
                  child: _ThemeTile(
                    option: option,
                    selected: prefs.theme == option,
                    onTap: () => unawaited(notifier.change((AppPreferences p) => p.copyWith(theme: option))),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AuroraSpacing.sm),
          Text(
            "System follows your phone's dark-mode setting.",
            style: context.caption,
          ),
          const SizedBox(height: AuroraSpacing.lg),
          Text("LOOK", style: context.mono(size: 11, color: context.inkSecondary).copyWith(letterSpacing: 0.8)),
          const SizedBox(height: AuroraSpacing.sm),
          AuroraRowGroup(
            children: <Widget>[
              AuroraSwitchRow(
                icon: Icons.edit_outlined,
                title: "Handwritten headlines",
                subtitle: "Friendly Patrick Hand titles. Off gives plain, neutral headings.",
                value: prefs.handwrittenHeadlines,
                onChanged: (bool on) =>
                    unawaited(notifier.change((AppPreferences p) => p.copyWith(handwrittenHeadlines: on))),
              ),
              AuroraSwitchRow(
                icon: Icons.auto_awesome_outlined,
                title: "Aurora gradients",
                subtitle: "The lavender-to-pink accent on main buttons and the selected tab.",
                value: prefs.gradients,
                onChanged: (bool on) => unawaited(notifier.change((AppPreferences p) => p.copyWith(gradients: on))),
              ),
            ],
          ),
          const SizedBox(height: AuroraSpacing.lg),
          Text("SPACING", style: context.mono(size: 11, color: context.inkSecondary).copyWith(letterSpacing: 0.8)),
          const SizedBox(height: AuroraSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<UiDensity>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<UiDensity>>[
                ButtonSegment<UiDensity>(value: UiDensity.compact, label: Text("Compact")),
                ButtonSegment<UiDensity>(value: UiDensity.comfortable, label: Text("Comfortable")),
                ButtonSegment<UiDensity>(value: UiDensity.expanded, label: Text("Expanded")),
              ],
              selected: <UiDensity>{prefs.density},
              onSelectionChanged: (Set<UiDensity> chosen) =>
                  unawaited(notifier.change((AppPreferences p) => p.copyWith(density: chosen.first))),
            ),
          ),
          const SizedBox(height: AuroraSpacing.sm),
          Text("How much room buttons, rows and lists get.", style: context.caption),
        ],
      ),
    );
  }
}

/// One of the three theme choices, drawn as a little preview of the page.
class _ThemeTile extends StatelessWidget {
  const _ThemeTile({required this.option, required this.selected, required this.onTap});

  final ThemePreference option;
  final bool selected;
  final VoidCallback onTap;

  static const Color _lightPage = Color(0xFFF0EEE9);
  static const Color _darkPage = Color(0xFF15151A);

  @override
  Widget build(BuildContext context) {
    final String label = switch (option) {
      ThemePreference.system => "System",
      ThemePreference.light => "Light",
      ThemePreference.dark => "Dark",
    };
    final String caption = switch (option) {
      ThemePreference.system => "Auto",
      ThemePreference.light => "Parchment",
      ThemePreference.dark => "Midnight",
    };

    return Semantics(
      button: true,
      selected: selected,
      label: "$label theme",
      child: InkWell(
        onTap: onTap,
        borderRadius: AuroraRadii.lgAll,
        child: Container(
          padding: const EdgeInsets.all(AuroraSpacing.sm),
          decoration: BoxDecoration(
            color: context.cardColor,
            borderRadius: AuroraRadii.lgAll,
            border: Border.all(
              color: selected ? context.scheme.primary : context.borderDefault,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            children: <Widget>[
              SizedBox(
                height: 56,
                width: double.infinity,
                child: ClipRRect(
                  borderRadius: AuroraRadii.standardAll,
                  child: switch (option) {
                    ThemePreference.system => Row(
                      children: const <Widget>[
                        Expanded(child: _Preview(page: _lightPage, card: Colors.white)),
                        Expanded(child: _Preview(page: _darkPage, card: Color(0xFF0F0F13))),
                      ],
                    ),
                    ThemePreference.light => const _Preview(page: _lightPage, card: Colors.white),
                    ThemePreference.dark => const _Preview(page: _darkPage, card: Color(0xFF0F0F13)),
                  },
                ),
              ),
              const SizedBox(height: AuroraSpacing.sm),
              ExcludeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    if (selected) ...<Widget>[
                      Icon(Icons.check_circle, size: 16, color: context.scheme.primary),
                      const SizedBox(width: 4),
                    ],
                    Text(label, style: AuroraTypography.labelLg.copyWith(color: context.inkPrimary)),
                  ],
                ),
              ),
              ExcludeSemantics(child: Text(caption, style: context.mono(size: 10, color: context.inkTertiary))),
            ],
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.page, required this.card});

  final Color page;
  final Color card;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: page,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: DecoratedBox(decoration: BoxDecoration(color: card, borderRadius: AuroraRadii.smAll))),
            const SizedBox(height: 4),
            Container(
              height: 8,
              decoration: const BoxDecoration(gradient: AuroraColors.primaryAurora, borderRadius: AuroraRadii.smAll),
            ),
          ],
        ),
      ),
    );
  }
}
