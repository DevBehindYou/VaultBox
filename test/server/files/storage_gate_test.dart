import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/domain/entities/protocol_storage_access.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/server/files/storage_gate.dart";

/// [ProtocolKind]-scoped visibility — the "Storage access" feature: each
/// protocol may be restricted to a subset of roots independently, and a
/// share link (ProtocolKind.shareLink) is never restricted at all.
void main() {
  const StorageRoot internal = StorageRoot(
    id: "internal",
    displayName: "Internal",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://internal",
    capabilities: StorageCapabilities.fullLocal(),
    isDefault: true,
  );
  const StorageRoot external = StorageRoot(
    id: "external",
    displayName: "SD card",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://external",
    capabilities: StorageCapabilities.fullLocal(),
  );

  StorageGate gateWith(ProtocolStorageAccess access) => StorageGate(
    roots: InMemoryStorageRootRepository(initial: <StorageRoot>[internal, external]),
    authorizer: const SingleAdminAuthorizer(),
    access: access,
  );

  group("unrestricted (default)", () {
    test("every enabled root is visible to every protocol", () async {
      final StorageGate gate = gateWith(const ProtocolStorageAccess());
      for (final ProtocolKind protocol in ProtocolKind.values) {
        final List<StorageRoot> visible = await gate.visibleRoots(protocol: protocol);
        expect(visible.map((StorageRoot r) => r.id), containsAll(<String>["internal", "external"]), reason: "$protocol");
      }
    });

    test("root() resolves any enabled root for any protocol", () async {
      final StorageGate gate = gateWith(const ProtocolStorageAccess());
      final StorageRoot resolved = await gate.root("external", protocol: ProtocolKind.ftp);
      expect(resolved.id, "external");
    });
  });

  group("restricted to one root", () {
    late StorageGate gate;
    setUp(() {
      gate = gateWith(const ProtocolStorageAccess(ftpRootIds: <String>{"internal"}));
    });

    test("visibleRoots hides the other root for that protocol", () async {
      final List<StorageRoot> visible = await gate.visibleRoots(protocol: ProtocolKind.ftp);
      expect(visible.map((StorageRoot r) => r.id), <String>["internal"]);
    });

    test("root() refuses the hidden root as rootNotFound (not forbidden — doesn't reveal it exists)", () async {
      await expectLater(
        gate.root("external", protocol: ProtocolKind.ftp),
        throwsA(isA<StorageFault>().having((StorageFault f) => f.kind, "kind", FaultKind.rootNotFound)),
      );
    });

    test("a different, unconfigured protocol still sees both roots", () async {
      final List<StorageRoot> visible = await gate.visibleRoots(protocol: ProtocolKind.webdav);
      expect(visible.map((StorageRoot r) => r.id), containsAll(<String>["internal", "external"]));
    });
  });

  test("restricted to zero roots (every box unchecked) hides everything from that protocol", () async {
    final StorageGate gate = gateWith(const ProtocolStorageAccess(webdavRootIds: <String>{}));
    final List<StorageRoot> visible = await gate.visibleRoots(protocol: ProtocolKind.webdav);
    expect(visible, isEmpty);
  });

  test("a share link is never restricted, even when every protocol with a card is", () async {
    final StorageGate gate = gateWith(
      const ProtocolStorageAccess(
        webPortalHttpsRootIds: <String>{},
        plainHttpRootIds: <String>{},
        webdavRootIds: <String>{},
        ftpRootIds: <String>{},
      ),
    );
    final StorageRoot resolved = await gate.root("external", protocol: ProtocolKind.shareLink);
    expect(resolved.id, "external");
  });

  test("ProtocolStorageAccess round-trips through toMap/fromMap, including zero-vs-unset", () {
    const ProtocolStorageAccess access = ProtocolStorageAccess(
      webPortalHttpsRootIds: <String>{"internal", "external"},
      ftpRootIds: <String>{},
      // plainHttp and webdav left null (unset/unrestricted).
    );
    final ProtocolStorageAccess restored = ProtocolStorageAccess.fromMap(access.toMap());
    expect(restored.webPortalHttpsRootIds, <String>{"internal", "external"});
    expect(restored.ftpRootIds, isEmpty);
    expect(restored.plainHttpRootIds, isNull);
    expect(restored.webdavRootIds, isNull);
  });
}
