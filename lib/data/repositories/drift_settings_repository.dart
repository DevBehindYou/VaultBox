import "../../domain/repositories/settings_repository.dart";
import "../db/app_database.dart";

final class DriftSettingsRepository implements SettingsRepository {
  const DriftSettingsRepository(this._db);

  final AppDatabase _db;

  @override
  Future<Map<String, String>> readAll() async {
    final List<AppSettingRow> rows = await _db.select(_db.appSettings).get();
    return <String, String>{for (final AppSettingRow row in rows) row.settingKey: row.settingValue};
  }

  @override
  Future<String?> read(String key) async {
    final AppSettingRow? row = await (_db.select(_db.appSettings)..where((AppSettings t) => t.settingKey.equals(key)))
        .getSingleOrNull();
    return row?.settingValue;
  }

  @override
  Future<void> write(String key, String value) async {
    await _db.into(_db.appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(settingKey: key, settingValue: value),
    );
  }

  @override
  Future<void> writeAll(Map<String, String> values) async {
    await _db.transaction(() async {
      for (final MapEntry<String, String> entry in values.entries) {
        await write(entry.key, entry.value);
      }
    });
  }
}
