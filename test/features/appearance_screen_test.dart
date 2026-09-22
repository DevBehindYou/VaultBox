import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/app_state.dart";
import "package:vaultbox/core/design/aurora_context.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/data/repositories/in_memory_settings_repository.dart";
import "package:vaultbox/domain/entities/app_preferences.dart";
import "package:vaultbox/domain/repositories/settings_repository.dart";
import "package:vaultbox/features/settings/presentation/appearance_screen.dart";

/// Appearance & Display: light, dark or follow the phone, headings, gradients and
/// spacing — chosen here, remembered, and available to the whole app.
void main() {
  late InMemorySettingsRepository store;
  late PreferencesCubit cubit;

  setUp(() => store = InMemorySettingsRepository());

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepositoryProvider<SettingsRepository>.value(
        value: store,
        child: MultiBlocProvider(
          providers: <BlocProvider<dynamic>>[
            BlocProvider<PreferencesCubit>(
              create: (BuildContext context) {
                cubit = PreferencesCubit(context.read<SettingsRepository>());
                return cubit;
              },
            ),
          ],
          child: MaterialApp(theme: AuroraTheme.light(), home: const AppearanceScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  AppPreferences current() => cubit.state;

  testWidgets("starts from the defaults and lists every choice", (WidgetTester tester) async {
    await show(tester);

    expect(find.text("Appearance & Display"), findsOneWidget);
    expect(find.text("System"), findsOneWidget);
    expect(find.text("Light"), findsOneWidget);
    expect(find.text("Dark"), findsOneWidget);
    expect(find.text("Handwritten headlines"), findsOneWidget);
    expect(find.text("Aurora gradients"), findsOneWidget);
    expect(find.text("Comfortable"), findsOneWidget);
    expect(current().theme, ThemePreference.system);
    expect(find.byIcon(Icons.check_circle), findsOneWidget, reason: "one theme is marked as chosen");
  });

  testWidgets("choosing Dark applies at once and is remembered", (WidgetTester tester) async {
    await show(tester);

    await tester.tap(find.text("Dark"));
    await tester.pumpAndSettle();

    expect(current().theme, ThemePreference.dark);
    expect((await store.readAll())["ui.theme"], "dark");
  });

  testWidgets("choosing Light, then System again, keeps exactly one theme chosen", (WidgetTester tester) async {
    await show(tester);

    await tester.tap(find.text("Light"));
    await tester.pumpAndSettle();
    expect(current().theme, ThemePreference.light);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.text("System"));
    await tester.pumpAndSettle();
    expect(current().theme, ThemePreference.system);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets("the two look switches change and save independently", (WidgetTester tester) async {
    await show(tester);

    await tester.tap(find.text("Handwritten headlines"));
    await tester.pumpAndSettle();
    expect(current().handwrittenHeadlines, isFalse);
    expect(current().gradients, isTrue, reason: "the other switch is untouched");

    await tester.tap(find.text("Aurora gradients"));
    await tester.pumpAndSettle();
    expect(current().gradients, isFalse);

    final Map<String, String> saved = await store.readAll();
    expect(saved["ui.handwritten"], "false");
    expect(saved["ui.gradients"], "false");
  });

  testWidgets("the spacing choice is saved", (WidgetTester tester) async {
    await show(tester);

    await tester.tap(find.text("Compact"));
    await tester.pumpAndSettle();
    expect(current().density, UiDensity.compact);

    await tester.tap(find.text("Expanded"));
    await tester.pumpAndSettle();
    expect(current().density, UiDensity.expanded);
    expect((await store.readAll())["ui.density"], "expanded");
  });

  testWidgets("earlier choices are loaded when the screen opens", (WidgetTester tester) async {
    store = InMemorySettingsRepository(const AppPreferences(theme: ThemePreference.dark, gradients: false).toMap());
    await show(tester);

    expect(current().theme, ThemePreference.dark);
    expect(current().gradients, isFalse);
  });

  group("the theme carries the look to every screen", () {
    Future<TextStyle> headingStyle(WidgetTester tester, ThemeData theme) async {
      late TextStyle style;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (BuildContext context) {
              style = context.brand(20);
              return const SizedBox();
            },
          ),
        ),
      );
      return style;
    }

    testWidgets("headings use Patrick Hand while handwritten headlines are on", (WidgetTester tester) async {
      final TextStyle style = await headingStyle(tester, AuroraTheme.light());

      expect(style.fontFamily, "Patrick Hand");
    });

    testWidgets("with them off, headings are a plain semibold sans", (WidgetTester tester) async {
      final TextStyle style = await headingStyle(
        tester,
        AuroraTheme.light(style: const AuroraStyle(handwrittenHeadlines: false)),
      );

      expect(style.fontFamily, isNull);
      expect(style.fontWeight, FontWeight.w600);
    });

    testWidgets("colours follow light and dark", (WidgetTester tester) async {
      late Color light;
      late Color dark;
      await tester.pumpWidget(
        MaterialApp(
          theme: AuroraTheme.light(),
          home: Builder(
            builder: (BuildContext context) {
              light = context.inkSecondary;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          theme: AuroraTheme.dark(),
          home: Builder(
            builder: (BuildContext context) {
              dark = context.inkSecondary;
              return const SizedBox();
            },
          ),
        ),
      );
      // The theme change animates; wait for it to land before looking.
      await tester.pumpAndSettle();

      expect(light, isNot(dark));
    });
  });
}
