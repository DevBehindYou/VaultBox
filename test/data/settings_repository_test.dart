import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/db/app_database.dart";
import "package:vaultbox/data/repositories/drift_settings_repository.dart";
import "package:vaultbox/data/repositories/in_memory_settings_repository.dart";
import "package:vaultbox/domain/entities/app_preferences.dart";
import "package:vaultbox/domain/repositories/settings_repository.dart";

/// One contract, two implementations, plus what the Appearance choices do with them.
void main() {
  group("InMemorySettingsRepository", () => _contract(() async => InMemorySettingsRepository()));

  group("DriftSettingsRepository", () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    _contract(() async => DriftSettingsRepository(db));
  });

  group("AppPreferences", () {
    test("the defaults are the design's: follow the phone, handwritten headlines, gradients, comfortable", () {
      const AppPreferences prefs = AppPreferences();

      expect(prefs.theme, ThemePreference.system);
      expect(prefs.handwrittenHeadlines, isTrue);
      expect(prefs.gradients, isTrue);
      expect(prefs.density, UiDensity.comfortable);
    });

    test("what is saved comes back the same", () {
      const AppPreferences chosen = AppPreferences(
        theme: ThemePreference.dark,
        handwrittenHeadlines: false,
        gradients: false,
        density: UiDensity.compact,
      );

      final AppPreferences back = AppPreferences.fromMap(chosen.toMap());

      expect(back.theme, ThemePreference.dark);
      expect(back.handwrittenHeadlines, isFalse);
      expect(back.gradients, isFalse);
      expect(back.density, UiDensity.compact);
    });

    test("an empty store gives the defaults", () {
      final AppPreferences prefs = AppPreferences.fromMap(const <String, String>{});

      expect(prefs.theme, ThemePreference.system);
      expect(prefs.handwrittenHeadlines, isTrue);
    });

    test("unrecognised values fall back instead of stopping the app", () {
      final AppPreferences prefs = AppPreferences.fromMap(const <String, String>{
        "ui.theme": "neon",
        "ui.density": "gigantic",
        "ui.handwritten": "maybe",
      });

      expect(prefs.theme, ThemePreference.system);
      expect(prefs.density, UiDensity.comfortable);
      expect(prefs.handwrittenHeadlines, isTrue, reason: "only an explicit 'false' turns it off");
    });

    test("copyWith changes one thing and keeps the rest", () {
      const AppPreferences base = AppPreferences(theme: ThemePreference.light, gradients: false);

      final AppPreferences next = base.copyWith(density: UiDensity.expanded);

      expect(next.theme, ThemePreference.light);
      expect(next.gradients, isFalse);
      expect(next.density, UiDensity.expanded);
    });

    test("saved through a repository and read back", () async {
      final InMemorySettingsRepository repo = InMemorySettingsRepository();

      await repo.writeAll(const AppPreferences(theme: ThemePreference.light, handwrittenHeadlines: false).toMap());

      final AppPreferences back = AppPreferences.fromMap(await repo.readAll());
      expect(back.theme, ThemePreference.light);
      expect(back.handwrittenHeadlines, isFalse);
    });
  });
}

void _contract(Future<SettingsRepository> Function() create) {
  late SettingsRepository repo;

  setUp(() async => repo = await create());

  test("a value that was never written is null, and reading all of nothing is empty", () async {
    expect(await repo.read("missing"), isNull);
    expect(await repo.readAll(), isEmpty);
  });

  test("a value is stored and read back", () async {
    await repo.write("ui.theme", "dark");

    expect(await repo.read("ui.theme"), "dark");
    expect(await repo.readAll(), <String, String>{"ui.theme": "dark"});
  });

  test("writing again replaces the value instead of adding a second one", () async {
    await repo.write("k", "one");
    await repo.write("k", "two");

    expect(await repo.read("k"), "two");
    expect(await repo.readAll(), hasLength(1));
  });

  test("several values are written together and keep the ones that weren't mentioned", () async {
    await repo.write("keep", "yes");
    await repo.writeAll(<String, String>{"a": "1", "b": "2", "keep": "still"});

    expect(await repo.readAll(), <String, String>{"a": "1", "b": "2", "keep": "still"});
  });
}
