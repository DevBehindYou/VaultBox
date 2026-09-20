import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/entities/app_preferences.dart";
import "providers.dart";

/// The person's Appearance choices, loaded once and saved on every change.
///
/// Only the app's root reads this (to build the theme). Everything below gets
/// its look from the theme, so screens don't need a database to render.
class PreferencesNotifier extends AsyncNotifier<AppPreferences> {
  @override
  Future<AppPreferences> build() async {
    return AppPreferences.fromMap(await ref.watch(settingsRepositoryProvider).readAll());
  }

  /// Applies [update] to what is current, shows it at once, then saves it.
  Future<void> change(AppPreferences Function(AppPreferences current) update) async {
    final AppPreferences next = update(state.value ?? const AppPreferences());
    state = AsyncData<AppPreferences>(next);
    await ref.read(settingsRepositoryProvider).writeAll(next.toMap());
  }
}

final AsyncNotifierProvider<PreferencesNotifier, AppPreferences> preferencesProvider =
    AsyncNotifierProvider<PreferencesNotifier, AppPreferences>(PreferencesNotifier.new);
