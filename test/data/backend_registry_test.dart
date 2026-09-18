import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/data/services/direct_path_storage_backend.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/data/services/saf_storage_backend.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";

import "../helpers/fake_android_storage_host.dart";

void main() {
  StorageRoot root(String id, StorageBackendType type, {String uri = "x", String? rootDocumentId}) =>
      StorageRoot(
        id: id,
        displayName: id,
        backendType: type,
        uriOrPath: uri,
        rootDocumentId: rootDocumentId,
        capabilities: const StorageCapabilities.fullLocal(),
      );

  test("builds the right backend for each root type", () {
    final BackendRegistry registry = BackendRegistry(host: FakeAndroidStorageHost());

    expect(registry.forRoot(root("m", StorageBackendType.memory)), isA<MemoryStorageBackend>());
    expect(
      registry.forRoot(root("d", StorageBackendType.direct, uri: "/tmp/somewhere")),
      isA<DirectPathStorageBackend>(),
    );
    final SafStorageBackend saf = registry.forRoot(
      root("s", StorageBackendType.saf, uri: "content://tree/x", rootDocumentId: "root"),
    ) as SafStorageBackend;
    expect(saf.id, "s");
  });

  test("caches one backend instance per root id", () {
    final BackendRegistry registry = BackendRegistry();
    final StorageRoot memory = root("m", StorageBackendType.memory);
    expect(identical(registry.forRoot(memory), registry.forRoot(memory)), isTrue);
  });

  test("a SAF root without a root document id fails loudly", () {
    final BackendRegistry registry = BackendRegistry(host: FakeAndroidStorageHost());
    expect(
      () => registry.forRoot(root("s", StorageBackendType.saf, uri: "content://tree/x")),
      throwsStateError,
    );
  });

  test("a SAF root with no native host available fails loudly", () {
    final BackendRegistry registry = BackendRegistry();
    expect(
      () => registry.forRoot(
        root("s", StorageBackendType.saf, uri: "content://tree/x", rootDocumentId: "root"),
      ),
      throwsStateError,
    );
  });

  test("SAF capabilities are honest (no native move, no atomic replace)", () {
    const StorageCapabilities caps = StorageCapabilities.saf();
    expect(caps.canWrite, isTrue);
    expect(caps.canMoveWithinBackend, isFalse);
    expect(caps.supportsAtomicReplace, isFalse);
  });
}
