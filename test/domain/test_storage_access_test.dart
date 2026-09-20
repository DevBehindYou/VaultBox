import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/models/file_ref.dart";
import "package:vaultbox/domain/usecases/test_storage_access.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";

import "../helpers/fake_clock.dart";

void main() {
  StorageRoot root({
    bool enabled = true,
    bool available = true,
    StorageCapabilities capabilities = const StorageCapabilities.fullLocal(),
  }) => StorageRoot(
    id: "mem",
    displayName: "Phone",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://phone",
    capabilities: capabilities,
    isEnabled: enabled,
    isAvailable: available,
  );

  late MemoryStorageBackend backend;
  late FileRepositoryImpl files;
  late TestStorageAccess access;

  setUp(() {
    backend = MemoryStorageBackend(id: "mem")..seedFile("/keep.txt", utf8.encode("mine"));
    final BackendRegistry registry = BackendRegistry()..register(backend);
    files = FileRepositoryImpl(resolveBackend: registry.forRoot);
    access = TestStorageAccess(files, FakeClock());
  });

  Future<bool> exists(String name) async =>
      await files.statEntry(FileRef(root: root(), path: StoragePath.root("mem").child(name))) != null;

  test("a working, writable location reads and writes, and leaves nothing behind", () async {
    final StorageTestResult result = await access(root());

    expect(result.ok, isTrue);
    expect(result.message, "Reading and writing both work.");
    expect(result.elapsed, isNotNull);
    expect(await exists(TestStorageAccess.testFileName), isFalse, reason: "the test file is cleaned up");
    expect(await exists("keep.txt"), isTrue, reason: "and nothing else is touched");
  });

  test("a leftover test file from an earlier run doesn't get in the way", () async {
    backend.seedFile("/${TestStorageAccess.testFileName}", utf8.encode("old"));

    final StorageTestResult result = await access(root());

    expect(result.ok, isTrue);
    expect(await exists(TestStorageAccess.testFileName), isFalse);
  });

  test("a read-only location is read but never written", () async {
    final StorageTestResult result = await access(root(capabilities: const StorageCapabilities.readOnly()));

    expect(result.ok, isTrue);
    expect(result.message, contains("read-only"));
    expect(await exists(TestStorageAccess.testFileName), isFalse);
  });

  test("a location that is off or unreachable says so without trying", () async {
    final StorageTestResult off = await access(root(enabled: false));
    final StorageTestResult gone = await access(root(available: false));

    expect(off.ok, isFalse);
    expect(off.message, contains("turned off"));
    expect(gone.ok, isFalse);
    expect(gone.message, contains("can't be reached"));
  });

  test("a backend that fails is reported, not thrown", () async {
    final StorageTestResult result = await TestStorageAccess(
      FileRepositoryImpl(resolveBackend: (StorageRoot r) => throw StateError("backend exploded")),
      FakeClock(),
    )(root());

    expect(result.ok, isFalse);
    expect(result.message, isNotEmpty);
  });
}
