/// Small key/value settings kept on the phone (appearance today; more later).
abstract interface class SettingsRepository {
  Future<Map<String, String>> readAll();

  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> writeAll(Map<String, String> values);
}
