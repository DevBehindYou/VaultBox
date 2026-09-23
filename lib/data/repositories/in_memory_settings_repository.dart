import "../../domain/repositories/settings_repository.dart";

/// Test fake for [SettingsRepository] — same contract as the Drift one.
final class InMemorySettingsRepository implements SettingsRepository {
  InMemorySettingsRepository([Map<String, String> initial = const <String, String>{}]) {
    _values.addAll(initial);
  }

  final Map<String, String> _values = <String, String>{};

  @override
  Future<Map<String, String>> readAll() async => Map<String, String>.of(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> writeAll(Map<String, String> values) async {
    _values.addAll(values);
  }
}
