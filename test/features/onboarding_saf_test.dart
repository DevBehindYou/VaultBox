import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/repositories/id_generator.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/features/onboarding/onboarding_actions.dart";
import "package:vaultbox/platform/adapters/android_storage_host.dart";

import "../helpers/fake_android_storage_host.dart";

final class _Ids implements IdGenerator {
  int _n = 0;
  @override
  String newId() => "id${_n++}";
}

/// "SD card or custom folder" registration logic, against a fake native host.
void main() {
  const SafTreeInfo docs = SafTreeInfo(
    treeUri: "content://com.android.externalstorage.documents/tree/primary%3ADocs",
    displayName: "Docs",
    rootDocumentId: "root", // the fake host's root node id
  );
  const SafTreeInfo sd = SafTreeInfo(
    treeUri: "content://com.android.externalstorage.documents/tree/1234-ABCD%3A",
    displayName: "SD card",
    rootDocumentId: "root",
  );

  late FakeAndroidStorageHost host;
  late BackendRegistry registry;
  late InMemoryStorageRootRepository roots;

  setUp(() {
    host = FakeAndroidStorageHost();
    registry = BackendRegistry(host: host);
    roots = InMemoryStorageRootRepository();
  });
  tearDown(() => roots.dispose());

  final _Ids ids = _Ids();
  Future<String?> register() =>
      registerSafRoot(host: host, registry: registry, roots: roots, ids: ids);

  test("a cancelled picker adds nothing", () async {
    host.nextTree = null;
    expect(await register(), isNull);
    expect(await roots.listRoots(), isEmpty);
  });

  test("registers the folder as a SAF root, proves it is writable, and makes it default", () async {
    host.nextTree = docs;
    final String? id = await register();

    final StorageRoot root = (await roots.listRoots()).single;
    expect(id, root.id);
    expect(root.backendType, StorageBackendType.saf);
    expect(root.uriOrPath, docs.treeUri);
    expect(root.rootDocumentId, "root");
    expect(root.displayName, "Docs");
    expect(root.isDefault, isTrue);
    expect(root.capabilities.canMoveWithinBackend, isFalse, reason: "SAF capabilities, not fullLocal");

    // The write probe really created the hidden bookkeeping folder in the tree.
    final StorageStat probe =
        await registry.forRoot(root).stat(StoragePath.parse(root.id, ".vaultbox"));
    expect(probe.exists, isTrue);
    expect(probe.type, StorageEntryType.directory);
  });

  test("picking the same folder twice returns the existing root", () async {
    host.nextTree = docs;
    final String? first = await register();
    final String? second = await register();

    expect(second, first);
    expect(await roots.listRoots(), hasLength(1));
  });

  test("a second, different folder does not steal the default", () async {
    host.nextTree = docs;
    await register();
    host.nextTree = sd;
    await register();

    final List<StorageRoot> all = await roots.listRoots();
    expect(all, hasLength(2));
    expect(all.where((StorageRoot r) => r.isDefault), hasLength(1));
    expect(all.firstWhere((StorageRoot r) => r.displayName == "Docs").isDefault, isTrue);
  });

  test("if the write probe fails, nothing is added and the grant is released", () async {
    host.nextTree = docs;
    host.failCreateDirectory = const PermissionRevokedFailure();

    await expectLater(register(), throwsA(isA<PermissionRevokedFailure>()));
    expect(await roots.listRoots(), isEmpty);
    expect(
      host.released,
      <String>[docs.treeUri],
      reason: "don't leave a useless persisted grant behind",
    );
  });
}
