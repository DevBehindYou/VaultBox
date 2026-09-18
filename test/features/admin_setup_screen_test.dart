import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/core/design/aurora_widgets.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/features/onboarding/presentation/admin_setup_screen.dart";

import "../helpers/fake_password_hasher.dart";

void main() {
  late InMemoryAccountRepository accounts;
  int done = 0;
  int skipped = 0;

  Widget harness({bool withSkip = false}) {
    return ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(accounts),
        passwordHasherProvider.overrideWithValue(FakePasswordHasher()),
      ],
      child: MaterialApp(
        theme: AuroraTheme.light(),
        home: AdminSetupScreen(
          stepLabel: "Step 3 of 3",
          skipLabel: withSkip ? "Skip for now" : null,
          onSkip: withSkip ? (BuildContext context) => skipped++ : null,
          onDone: (BuildContext context) => done++,
        ),
      ),
    );
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  bool submitEnabled(WidgetTester tester) =>
      tester.widget<AuroraPrimaryButton>(find.byType(AuroraPrimaryButton)).onPressed != null;

  setUp(() {
    accounts = InMemoryAccountRepository();
    done = 0;
    skipped = 0;
  });

  testWidgets("Create is disabled until username, password and confirmation are all valid", (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    expect(submitEnabled(tester), isFalse);

    await tester.enterText(field("Username"), "admin");
    await tester.enterText(field("Password"), "correct horse battery");
    await tester.pump();
    expect(submitEnabled(tester), isFalse, reason: "not confirmed yet");

    await tester.enterText(field("Confirm password"), "correct horse battery");
    await tester.pump();
    expect(submitEnabled(tester), isTrue);
  });

  testWidgets("live feedback comes from the real policies", (WidgetTester tester) async {
    await tester.pumpWidget(harness());

    await tester.enterText(field("Username"), "ab");
    await tester.enterText(field("Password"), "short");
    await tester.enterText(field("Confirm password"), "different");
    await tester.pump();

    expect(find.text("Use at least 3 characters."), findsOneWidget);
    expect(find.text("Use at least 12 characters."), findsOneWidget);
    expect(find.text("The passwords don't match."), findsOneWidget);
    expect(submitEnabled(tester), isFalse);
  });

  testWidgets("a password containing the username is refused", (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.enterText(field("Username"), "administrator");
    await tester.enterText(field("Password"), "my-Administrator-pass");
    await tester.pump();

    expect(find.text("Don't include your username in the password."), findsOneWidget);
    expect(submitEnabled(tester), isFalse);
  });

  testWidgets("submitting stores a hashed, lower-cased account and finishes", (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.enterText(field("Username"), "Admin");
    await tester.enterText(field("Password"), "correct horse battery");
    await tester.enterText(field("Confirm password"), "correct horse battery");
    await tester.pump();

    await tester.tap(find.text("Create account"));
    await tester.pumpAndSettle();

    expect(done, 1);
    final Account? stored = await accounts.findByUsername("admin");
    expect(stored, isNotNull);
    expect(stored!.passwordHash, isNot("correct horse battery"));
  });

  testWidgets("if an admin already exists the person is told, and nothing changes", (WidgetTester tester) async {
    accounts = InMemoryAccountRepository(<Account>[
      Account(id: "1", username: "owner", passwordHash: "x", createdAt: DateTime.utc(2026)),
    ]);
    await tester.pumpWidget(harness());
    await tester.enterText(field("Username"), "admin");
    await tester.enterText(field("Password"), "correct horse battery");
    await tester.enterText(field("Confirm password"), "correct horse battery");
    await tester.pump();

    await tester.tap(find.text("Create account"));
    await tester.pumpAndSettle();

    expect(find.text("An admin account already exists."), findsOneWidget);
    expect(done, 0);
    expect(await accounts.count(), 1);
  });

  testWidgets("Skip only appears in onboarding and calls onSkip", (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    expect(find.text("Skip for now"), findsNothing);

    await tester.pumpWidget(harness(withSkip: true));
    await tester.tap(find.text("Skip for now"));
    await tester.pump();
    expect(skipped, 1);
  });

  testWidgets("the password is hidden until asked, and the toggle works", (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    expect(tester.widget<TextField>(field("Password")).obscureText, isTrue);

    await tester.tap(find.byTooltip("Show password"));
    await tester.pump();
    expect(tester.widget<TextField>(field("Password")).obscureText, isFalse);
  });
}
