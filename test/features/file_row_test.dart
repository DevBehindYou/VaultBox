import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/design/aurora_colors.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/features/files/presentation/widgets/file_row.dart";

/// Regression for a bug only a real phone showed: in dark mode the selected
/// row used the LIGHT theme's near-white highlight, so its light text became
/// unreadable.
void main() {
  final StorageEntry entry = StorageEntry(
    path: StoragePath.root("r").child("Photos"),
    type: StorageEntryType.directory,
  );

  Future<Color?> selectedRowFill(WidgetTester tester, ThemeData theme) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: FileRow(entry: entry, selected: true, selectionMode: true, onTap: () {}),
        ),
      ),
    );
    final Finder materials = find.descendant(
      of: find.byType(FileRow),
      matching: find.byType(Material),
    );
    return tester.widget<Material>(materials.first).color;
  }

  testWidgets("dark theme: selected row uses the dark selection fill", (WidgetTester tester) async {
    expect(await selectedRowFill(tester, AuroraTheme.dark()), AuroraColorsDark.selectionSoft);
  });

  testWidgets("light theme: selected row still uses the light selection fill", (WidgetTester tester) async {
    expect(await selectedRowFill(tester, AuroraTheme.light()), AuroraColors.selectionSoft);
  });

  test("dark selection fill is actually dark (readable under light text)", () {
    expect(AuroraColorsDark.selectionSoft.computeLuminance(), lessThan(0.2));
    expect(AuroraColors.selectionSoft.computeLuminance(), greaterThan(0.8));
  });
}
