import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/services/saf_storage_backend.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";

import "../helpers/fake_android_storage_host.dart";

/// **Scope note, read before extending this file.** [SafStorageBackend]'s
/// `openRead`/`openWrite`/`copy` depend on `File('/proc/self/fd/$fd')` — a
/// real Android/Linux kernel feature backed by an actual open file
/// descriptor on the native side (see the class's own doc comment and
/// `pigeons/storage_api.dart`). `dart:io` has no portable way to fabricate a
/// raw OS file descriptor from pure Dart, so [FakeAndroidStorageHost] below
/// cannot faithfully back those three methods — faking them would mean
/// testing a fake's behaviour, not the class's. Untested here on purpose,
/// not by oversight; validating the byte-I/O path is on-device/integration
/// work (docs/IMPLEMENTATION_PLAN.md risk register).
///
/// Everything this file DOES cover — path→documentId resolution,
/// list/stat/createDirectory/rename/delete, and the metadata half of `copy`
/// (directory recursion, conflict detection) — has no such dependency and is
/// fully exercised here.
void main() {
  late FakeAndroidStorageHost host;
  late SafStorageBackend backend;

  setUp(() {
    host = FakeAndroidStorageHost();
    backend = SafStorageBackend(
      id: "saf-1",
      host: host,
      treeUri: "content://com.android.externalstorage.documents/tree/primary",
      rootDocumentId: "root",
    );
  });

  StoragePath at(String path) => StoragePath.parse("saf-1", path);

  test("stat reports non-existence for an unknown path without throwing", () async {
    final StorageStat stat = await backend.stat(at("nope.txt"));
    expect(stat.exists, isFalse);
  });

  test("createDirectory then stat resolves it as a directory", () async {
    await backend.createDirectory(at("Photos"));
    final StorageStat stat = await backend.stat(at("Photos"));

    expect(stat.exists, isTrue);
    expect(stat.type, StorageEntryType.directory);
  });

  test("createDirectory rejects a duplicate name", () async {
    await backend.createDirectory(at("Photos"));
    expect(
      () => backend.createDirectory(at("Photos")),
      throwsA(isA<PathConflictFailure>()),
    );
  });

  test("list resolves nested paths by walking documentIds level by level", () async {
    await backend.createDirectory(at("Photos"));
    await backend.createDirectory(at("Photos/2026"));
    host.seedFile(parentPath: <String>["Photos", "2026"], name: "beach.jpg", sizeBytes: 4200);

    final List<StorageEntry> entries = await backend.list(at("Photos/2026")).toList();
    expect(entries.map((StorageEntry e) => e.name), <String>["beach.jpg"]);
    expect(entries.single.sizeBytes, 4200);
  });

  test("list on an unknown directory reports StorageDisconnectedFailure", () async {
    expect(
      () => backend.list(at("nowhere")).toList(),
      throwsA(isA<StorageDisconnectedFailure>()),
    );
  });

  test("rename changes the name the entry is found under", () async {
    await backend.createDirectory(at("Old"));
    await backend.rename(at("Old"), "New");

    expect((await backend.stat(at("Old"))).exists, isFalse);
    expect((await backend.stat(at("New"))).exists, isTrue);
  });

  test("delete removes the entry", () async {
    await backend.createDirectory(at("Temp"));
    await backend.delete(at("Temp"));
    expect((await backend.stat(at("Temp"))).exists, isFalse);
  });

  test("copy of an empty directory tree recurses without touching file I/O", () async {
    await backend.createDirectory(at("Src"));
    await backend.createDirectory(at("Src/Inner"));

    await backend.copy(at("Src"), at("Dst"));

    expect((await backend.stat(at("Dst"))).exists, isTrue);
    expect((await backend.stat(at("Dst/Inner"))).exists, isTrue);
  });

  test("copy refuses to clobber an existing target", () async {
    await backend.createDirectory(at("A"));
    await backend.createDirectory(at("B"));
    expect(
      () => backend.copy(at("A"), at("B")),
      throwsA(isA<PathConflictFailure>()),
    );
  });
}
