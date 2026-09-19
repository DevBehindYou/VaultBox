import "package:drift/drift.dart";

import "../../domain/entities/share.dart";
import "../../domain/repositories/share_repository.dart";
import "../db/app_database.dart";

final class DriftShareRepository implements ShareRepository {
  const DriftShareRepository(this._db);

  final AppDatabase _db;

  @override
  Future<void> add(Share share) async {
    await _db.into(_db.shares).insert(
      SharesCompanion.insert(
        id: share.id,
        kind: share.kind.name,
        rootId: share.rootId,
        path: share.path,
        isDirectory: share.isDirectory,
        createdBy: share.createdBy,
        createdAt: share.createdAt,
        tokenHash: share.tokenHash,
        label: Value<String?>(share.label),
        expiresAt: Value<DateTime?>(share.expiresAt),
        passwordHash: Value<String?>(share.passwordHash),
        maxUses: Value<int?>(share.maxUses),
        useCount: Value<int>(share.useCount),
        maxFileBytes: Value<int?>(share.maxFileBytes),
      ),
    );
  }

  @override
  Future<Share?> get(String id) async {
    final ShareRow? row = await (_db.select(_db.shares)..where((Shares t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toEntity(row);
  }

  @override
  Future<Share?> findByTokenHash(String tokenHash) async {
    final ShareRow? row = await (_db.select(_db.shares)..where((Shares t) => t.tokenHash.equals(tokenHash))).getSingleOrNull();
    return row == null ? null : _toEntity(row);
  }

  @override
  Future<List<Share>> list() async {
    final List<ShareRow> rows = await (_db.select(_db.shares)
          ..orderBy(<OrderClauseGenerator<Shares>>[(Shares t) => OrderingTerm.desc(t.createdAt)]))
        .get();
    return <Share>[for (final ShareRow row in rows) _toEntity(row)];
  }

  @override
  Future<void> delete(String id) async {
    await (_db.delete(_db.shares)..where((Shares t) => t.id.equals(id))).go();
  }

  @override
  Future<void> deleteByCreator(String accountId) async {
    await (_db.delete(_db.shares)..where((Shares t) => t.createdBy.equals(accountId))).go();
  }

  @override
  Future<bool> tryUse(String id, DateTime now) {
    return _db.transaction(() async {
      final ShareRow? row = await (_db.select(_db.shares)..where((Shares t) => t.id.equals(id))).getSingleOrNull();
      if (row == null) return false;
      final Share share = _toEntity(row);
      if (!share.isActive(now)) return false;
      await (_db.update(_db.shares)..where((Shares t) => t.id.equals(id))).write(
        SharesCompanion(useCount: Value<int>(row.useCount + 1)),
      );
      return true;
    });
  }

  static Share _toEntity(ShareRow row) => Share(
    id: row.id,
    kind: ShareKind.values.firstWhere((ShareKind k) => k.name == row.kind, orElse: () => ShareKind.download),
    rootId: row.rootId,
    path: row.path,
    isDirectory: row.isDirectory,
    createdBy: row.createdBy,
    createdAt: row.createdAt,
    tokenHash: row.tokenHash,
    label: row.label,
    expiresAt: row.expiresAt,
    passwordHash: row.passwordHash,
    maxUses: row.maxUses,
    useCount: row.useCount,
    maxFileBytes: row.maxFileBytes,
  );
}
