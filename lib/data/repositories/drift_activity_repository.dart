import "package:drift/drift.dart";

import "../../domain/entities/activity.dart";
import "../../domain/repositories/activity_repository.dart";
import "../db/app_database.dart";

final class DriftActivityRepository implements ActivityRepository {
  const DriftActivityRepository(this._db);

  final AppDatabase _db;

  // ---------------------------------------------------------------- events

  @override
  Future<void> addEvent(ActivityEvent event) async {
    await _db.into(_db.activityEvents).insert(
      ActivityEventsCompanion.insert(
        id: event.id,
        occurredAt: event.at,
        kind: event.kind.name,
        severity: event.severity.name,
        message: event.message,
        actor: Value<String?>(event.actor),
        address: Value<String?>(event.address),
      ),
    );
  }

  @override
  Future<List<ActivityEvent>> recentEvents({int limit = 200}) async {
    final List<ActivityEventRow> rows = await (_db.select(_db.activityEvents)
          ..orderBy(<OrderClauseGenerator<ActivityEvents>>[
            (ActivityEvents t) => OrderingTerm.desc(t.occurredAt),
            // Same second: the one written last is newer.
            (ActivityEvents t) => OrderingTerm.desc(CustomExpression<int>("rowid")),
          ])
          ..limit(limit))
        .get();
    return <ActivityEvent>[
      for (final ActivityEventRow row in rows)
        ActivityEvent(
          id: row.id,
          at: row.occurredAt,
          kind: ActivityKind.values.firstWhere((ActivityKind k) => k.name == row.kind, orElse: () => ActivityKind.other),
          severity: ActivitySeverity.values.firstWhere(
            (ActivitySeverity s) => s.name == row.severity,
            orElse: () => ActivitySeverity.info,
          ),
          message: row.message,
          actor: row.actor,
          address: row.address,
        ),
    ];
  }

  // ------------------------------------------------------------- transfers

  @override
  Future<void> beginTransfer(TransferRecord transfer) async {
    await _db.into(_db.transferLog).insert(
      TransferLogCompanion.insert(
        id: transfer.id,
        direction: transfer.direction.name,
        via: transfer.via.name,
        actor: transfer.actor,
        name: transfer.name,
        startedAt: transfer.startedAt,
        updatedAt: transfer.updatedAt,
        finishedAt: Value<DateTime?>(transfer.finishedAt),
        bytes: Value<int>(transfer.bytes),
        totalBytes: Value<int?>(transfer.totalBytes),
        state: transfer.state.name,
      ),
    );
  }

  @override
  Future<void> updateTransferProgress(String id, {required int bytes, required DateTime at}) async {
    await (_db.update(_db.transferLog)
          ..where((TransferLog t) => t.id.equals(id) & t.state.equals(TransferState.running.name)))
        .write(TransferLogCompanion(bytes: Value<int>(bytes), updatedAt: Value<DateTime>(at)));
  }

  @override
  Future<void> finishTransfer(
    String id, {
    required TransferState state,
    required int bytes,
    required DateTime at,
  }) async {
    await (_db.update(_db.transferLog)..where((TransferLog t) => t.id.equals(id))).write(
      TransferLogCompanion(
        state: Value<String>(state.name),
        bytes: Value<int>(bytes),
        updatedAt: Value<DateTime>(at),
        finishedAt: Value<DateTime?>(at),
      ),
    );
  }

  @override
  Future<List<TransferRecord>> recentTransfers({int limit = 200}) async {
    final List<TransferRow> running = await (_db.select(_db.transferLog)
          ..where((TransferLog t) => t.state.equals(TransferState.running.name))
          ..orderBy(<OrderClauseGenerator<TransferLog>>[(TransferLog t) => OrderingTerm.desc(t.startedAt)]))
        .get();
    final List<TransferRow> finished = await (_db.select(_db.transferLog)
          ..where((TransferLog t) => t.state.equals(TransferState.running.name).not())
          ..orderBy(<OrderClauseGenerator<TransferLog>>[
            (TransferLog t) => OrderingTerm.desc(t.startedAt),
            (TransferLog t) => OrderingTerm.desc(CustomExpression<int>("rowid")),
          ])
          ..limit(limit))
        .get();
    return <TransferRecord>[
      for (final TransferRow row in <TransferRow>[...running, ...finished].take(limit)) _transferOf(row),
    ];
  }

  static TransferRecord _transferOf(TransferRow row) => TransferRecord(
    id: row.id,
    direction: TransferDirection.values.firstWhere(
      (TransferDirection d) => d.name == row.direction,
      orElse: () => TransferDirection.download,
    ),
    via: AccessVia.values.firstWhere((AccessVia v) => v.name == row.via, orElse: () => AccessVia.web),
    actor: row.actor,
    name: row.name,
    startedAt: row.startedAt,
    updatedAt: row.updatedAt,
    finishedAt: row.finishedAt,
    bytes: row.bytes,
    totalBytes: row.totalBytes,
    state: TransferState.values.firstWhere((TransferState s) => s.name == row.state, orElse: () => TransferState.failed),
  );

  // --------------------------------------------------------------- clients

  @override
  Future<void> touchClient(ClientRecord client) async {
    await _db.transaction(() async {
      final ClientRow? known = await (_db.select(_db.clientSightings)
            ..where((ClientSightings t) => t.clientKey.equals(client.key)))
          .getSingleOrNull();
      if (known == null) {
        await _db.into(_db.clientSightings).insert(
          ClientSightingsCompanion.insert(
            clientKey: client.key,
            actor: client.actor,
            address: client.address,
            via: client.via.name,
            firstSeenAt: client.firstSeenAt,
            lastSeenAt: client.lastSeenAt,
          ),
        );
      } else {
        await (_db.update(_db.clientSightings)..where((ClientSightings t) => t.clientKey.equals(client.key))).write(
          ClientSightingsCompanion(via: Value<String>(client.via.name), lastSeenAt: Value<DateTime>(client.lastSeenAt)),
        );
      }
    });
  }

  @override
  Future<List<ClientRecord>> recentClients({required DateTime since}) async {
    final List<ClientRow> rows = await (_db.select(_db.clientSightings)
          ..where((ClientSightings t) => t.lastSeenAt.isBiggerOrEqualValue(since))
          ..orderBy(<OrderClauseGenerator<ClientSightings>>[(ClientSightings t) => OrderingTerm.desc(t.lastSeenAt)]))
        .get();
    return <ClientRecord>[
      for (final ClientRow row in rows)
        ClientRecord(
          actor: row.actor,
          address: row.address,
          via: AccessVia.values.firstWhere((AccessVia v) => v.name == row.via, orElse: () => AccessVia.web),
          firstSeenAt: row.firstSeenAt,
          lastSeenAt: row.lastSeenAt,
        ),
    ];
  }

  // ----------------------------------------------------------- housekeeping

  @override
  Future<int> interruptRunningTransfers(DateTime at) {
    return (_db.update(_db.transferLog)..where((TransferLog t) => t.state.equals(TransferState.running.name))).write(
      TransferLogCompanion(
        state: Value<String>(TransferState.interrupted.name),
        updatedAt: Value<DateTime>(at),
        finishedAt: Value<DateTime?>(at),
      ),
    );
  }

  @override
  Future<void> prune({required DateTime before, int keepEvents = 1000, int keepTransfers = 500}) async {
    await _db.transaction(() async {
      await (_db.delete(_db.activityEvents)..where((ActivityEvents t) => t.occurredAt.isSmallerThanValue(before))).go();
      final List<ActivityEventRow> extraEvents = await (_db.select(_db.activityEvents)
            ..orderBy(<OrderClauseGenerator<ActivityEvents>>[
              (ActivityEvents t) => OrderingTerm.desc(t.occurredAt),
              (ActivityEvents t) => OrderingTerm.desc(CustomExpression<int>("rowid")),
            ])
            ..limit(1 << 30, offset: keepEvents))
          .get();
      if (extraEvents.isNotEmpty) {
        final List<String> ids = <String>[for (final ActivityEventRow row in extraEvents) row.id];
        await (_db.delete(_db.activityEvents)..where((ActivityEvents t) => t.id.isIn(ids))).go();
      }

      await (_db.delete(_db.transferLog)
            ..where(
              (TransferLog t) => t.state.equals(TransferState.running.name).not() & t.startedAt.isSmallerThanValue(before),
            ))
          .go();
      final List<TransferRow> extraTransfers = await (_db.select(_db.transferLog)
            ..orderBy(<OrderClauseGenerator<TransferLog>>[
              (TransferLog t) => OrderingTerm.desc(t.startedAt),
              (TransferLog t) => OrderingTerm.desc(CustomExpression<int>("rowid")),
            ])
            ..limit(1 << 30, offset: keepTransfers))
          .get();
      final List<String> transferIds = <String>[
        for (final TransferRow row in extraTransfers)
          if (row.state != TransferState.running.name) row.id,
      ];
      if (transferIds.isNotEmpty) {
        await (_db.delete(_db.transferLog)..where((TransferLog t) => t.id.isIn(transferIds))).go();
      }

      await (_db.delete(_db.clientSightings)..where((ClientSightings t) => t.lastSeenAt.isSmallerThanValue(before))).go();
    });
  }

  @override
  Future<void> clear() async {
    await _db.transaction(() async {
      await _db.delete(_db.activityEvents).go();
      await _db.delete(_db.transferLog).go();
      await _db.delete(_db.clientSightings).go();
    });
  }
}
