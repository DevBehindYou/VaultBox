import "dart:async";

import "../../domain/entities/recycle_item.dart";
import "../../domain/repositories/recycle_bin_repository.dart";

/// Test fake for [RecycleBinRepository] (doc §59) — superseded as the
/// runtime default by `DriftRecycleBinRepository` (see `app/providers.dart`).
/// Kept for tests that want restore-metadata behaviour without a real
/// database: recycle metadata here never survives past the
/// `ProviderContainer`/widget-test lifetime, which is exactly what a fast
/// unit test wants and exactly what production must NOT do.
final class InMemoryRecycleBinRepository implements RecycleBinRepository {
  final Map<String, RecycleItem> _items = <String, RecycleItem>{};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Stream<List<RecycleItem>> watchItems(String storageRootId) async* {
    yield _snapshot(storageRootId);
    yield* _changes.stream.map((_) => _snapshot(storageRootId));
  }

  @override
  Future<List<RecycleItem>> listItems(String storageRootId) async =>
      _snapshot(storageRootId);

  @override
  Future<void> add(RecycleItem item) async {
    _items[item.id] = item;
    _changes.add(null);
  }

  @override
  Future<RecycleItem?> get(String id) async => _items[id];

  @override
  Future<void> remove(String id) async {
    _items.remove(id);
    _changes.add(null);
  }

  List<RecycleItem> _snapshot(String storageRootId) {
    final List<RecycleItem> matching = _items.values
        .where((RecycleItem i) => i.storageRootId == storageRootId)
        .toList()
      ..sort((RecycleItem a, RecycleItem b) => b.deletedAt.compareTo(a.deletedAt));
    return List<RecycleItem>.unmodifiable(matching);
  }

  Future<void> dispose() => _changes.close();
}
