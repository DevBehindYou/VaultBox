import "dart:async";

import "../../domain/entities/storage_root.dart";
import "../../domain/repositories/storage_root_repository.dart";

/// Test fake for [StorageRootRepository] (doc §59). No longer the default
/// runtime implementation — `app/providers.dart` wires
/// `DriftStorageRootRepository` there now, so a real app install keeps its
/// roots across restarts. This class stays as the fast, dependency-free
/// double for widget/unit tests that want a `StorageRootRepository` without
/// pulling in a real (or even in-memory) sqlite database.
final class InMemoryStorageRootRepository implements StorageRootRepository {
  InMemoryStorageRootRepository({List<StorageRoot> initial = const <StorageRoot>[]}) {
    _roots.addAll(initial);
    _controller.add(List<StorageRoot>.unmodifiable(_roots));
  }

  final List<StorageRoot> _roots = <StorageRoot>[];
  final StreamController<List<StorageRoot>> _controller =
      StreamController<List<StorageRoot>>.broadcast();

  @override
  Stream<List<StorageRoot>> watchRoots() async* {
    // Broadcast streams have no replay (KB vol2 §9.3) — emit the current
    // snapshot to each new subscriber so a late-subscribing ViewModel isn't
    // left waiting for the next mutation to render anything.
    yield List<StorageRoot>.unmodifiable(_roots);
    yield* _controller.stream;
  }

  @override
  Future<List<StorageRoot>> listRoots() async => List<StorageRoot>.unmodifiable(_roots);

  @override
  Future<StorageRoot?> getRoot(String id) async {
    for (final StorageRoot root in _roots) {
      if (root.id == id) return root;
    }
    return null;
  }

  @override
  Future<void> addRoot(StorageRoot root) async {
    _roots.add(root);
    _emit();
  }

  @override
  Future<void> updateRoot(StorageRoot root) async {
    final int index = _roots.indexWhere((StorageRoot r) => r.id == root.id);
    if (index == -1) return;
    _roots[index] = root;
    _emit();
  }

  @override
  Future<void> removeRoot(String id) async {
    _roots.removeWhere((StorageRoot r) => r.id == id);
    _emit();
  }

  @override
  Future<void> setDefault(String id) async {
    for (int i = 0; i < _roots.length; i++) {
      _roots[i] = _roots[i].copyWith(isDefault: _roots[i].id == id);
    }
    _emit();
  }

  void _emit() => _controller.add(List<StorageRoot>.unmodifiable(_roots));

  Future<void> dispose() => _controller.close();
}
