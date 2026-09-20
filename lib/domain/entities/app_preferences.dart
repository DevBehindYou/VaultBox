/// Which colour scheme the app uses.
enum ThemePreference {
  /// Follow the phone's dark-mode setting.
  system,
  light,
  dark,
}

/// How much room rows and buttons get.
enum UiDensity { compact, comfortable, expanded }

/// What a person chose in Appearance. Small on purpose: every field changes
/// something you can see, and every field has a sensible default.
final class AppPreferences {
  const AppPreferences({
    this.theme = ThemePreference.system,
    this.handwrittenHeadlines = true,
    this.gradients = true,
    this.density = UiDensity.comfortable,
  });

  final ThemePreference theme;

  /// Patrick Hand for page and card titles; off gives a plain sans.
  final bool handwrittenHeadlines;

  /// The lavender-to-pink accent on primary buttons.
  final bool gradients;
  final UiDensity density;

  AppPreferences copyWith({
    ThemePreference? theme,
    bool? handwrittenHeadlines,
    bool? gradients,
    UiDensity? density,
  }) => AppPreferences(
    theme: theme ?? this.theme,
    handwrittenHeadlines: handwrittenHeadlines ?? this.handwrittenHeadlines,
    gradients: gradients ?? this.gradients,
    density: density ?? this.density,
  );

  static const String _themeKey = "ui.theme";
  static const String _handwrittenKey = "ui.handwritten";
  static const String _gradientsKey = "ui.gradients";
  static const String _densityKey = "ui.density";

  /// What gets stored. Only values that differ are the person's choice, but
  /// writing all of them keeps the store easy to read.
  Map<String, String> toMap() => <String, String>{
    _themeKey: theme.name,
    _handwrittenKey: handwrittenHeadlines.toString(),
    _gradientsKey: gradients.toString(),
    _densityKey: density.name,
  };

  /// Reads what [toMap] wrote. Anything missing or unrecognised falls back to
  /// its default, so a newer or damaged store can't stop the app from opening.
  factory AppPreferences.fromMap(Map<String, String> map) {
    T pick<T extends Enum>(List<T> values, String? name, T fallback) {
      for (final T value in values) {
        if (value.name == name) return value;
      }
      return fallback;
    }

    return AppPreferences(
      theme: pick(ThemePreference.values, map[_themeKey], ThemePreference.system),
      handwrittenHeadlines: map[_handwrittenKey] != "false",
      gradients: map[_gradientsKey] != "false",
      density: pick(UiDensity.values, map[_densityKey], UiDensity.comfortable),
    );
  }
}
