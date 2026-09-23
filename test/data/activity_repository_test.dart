import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/db/app_database.dart";
import "package:vaultbox/data/repositories/drift_activity_repository.dart";
import "package:vaultbox/data/repositories/in_memory_activity_repository.dart";
import "package:vaultbox/domain/entities/activity.dart";
import "package:vaultbox/domain/repositories/activity_repository.dart";

/// One contract, two implementations: the in-memory fake the tests lean on and
/// the Drift one the app ships must behave the same.
void main() {
  group("InMemoryActivityRepository", () => _contract(() async => InMemoryActivityRepository()));

  group("DriftActivityRepository", () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    _contract(() async => DriftActivityRepository(db));
  });
}

/// Whole seconds only: the database keeps seconds.
final DateTime _t0 = DateTime.utc(2026, 9, 20, 12);

DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

ActivityEvent _event(String id, int seconds, {ActivityKind kind = ActivityKind.signedIn, String? actor, String? address}) =>
    ActivityEvent(id: id, at: _at(seconds), kind: kind, message: "message $id", actor: actor, address: address);

TransferRecord _transfer(
  String id,
  int seconds, {
  TransferDirection direction = TransferDirection.download,
  int? total,
}) => TransferRecord(
  id: id,
  direction: direction,
  via: AccessVia.web,
  actor: "admin",
  name: "$id.bin",
  startedAt: _at(seconds),
  updatedAt: _at(seconds),
  totalBytes: total,
);

void _contract(Future<ActivityRepository> Function() create) {
  late ActivityRepository repo;

  setUp(() async => repo = await create());

  group("events", () {
    test("come back newest first, capped by the limit", () async {
      await repo.addEvent(_event("a", 1));
      await repo.addEvent(_event("b", 3));
      await repo.addEvent(_event("c", 2));

      expect((await repo.recentEvents()).map((ActivityEvent e) => e.id), <String>["b", "c", "a"]);
      expect((await repo.recentEvents(limit: 2)).map((ActivityEvent e) => e.id), <String>["b", "c"]);
    });

    test("the one written last is newer when the time is the same", () async {
      await repo.addEvent(_event("first", 5));
      await repo.addEvent(_event("second", 5));

      expect((await repo.recentEvents()).map((ActivityEvent e) => e.id), <String>["second", "first"]);
    });

    test("keep every field", () async {
      await repo.addEvent(
        ActivityEvent(
          id: "e1",
          at: _at(0),
          kind: ActivityKind.signInRefused,
          message: "A sign-in was refused.",
          severity: ActivitySeverity.warning,
          address: "192.168.1.9",
        ),
      );
      await repo.addEvent(_event("e2", 1, actor: "bob"));

      final List<ActivityEvent> events = await repo.recentEvents();
      final ActivityEvent refused = events.firstWhere((ActivityEvent e) => e.id == "e1");
      expect(refused.kind, ActivityKind.signInRefused);
      expect(refused.severity, ActivitySeverity.warning);
      expect(refused.message, "A sign-in was refused.");
      expect(refused.address, "192.168.1.9");
      expect(refused.actor, isNull);
      expect(refused.at.toUtc(), _at(0));
      expect(events.firstWhere((ActivityEvent e) => e.id == "e2").actor, "bob");
    });
  });

  group("transfers", () {
    test("a transfer is begun, moves, and is finished", () async {
      await repo.beginTransfer(_transfer("t1", 0, total: 1000));
      await repo.updateTransferProgress("t1", bytes: 400, at: _at(2));

      TransferRecord t = (await repo.recentTransfers()).single;
      expect(t.state, TransferState.running);
      expect(t.bytes, 400);
      expect(t.fraction, 0.4);
      expect(t.updatedAt.toUtc(), _at(2));
      expect(t.finishedAt, isNull);

      await repo.finishTransfer("t1", state: TransferState.completed, bytes: 1000, at: _at(5));
      t = (await repo.recentTransfers()).single;
      expect(t.state, TransferState.completed);
      expect(t.bytes, 1000);
      expect(t.finishedAt!.toUtc(), _at(5));
    });

    test("progress can't reopen a finished transfer", () async {
      await repo.beginTransfer(_transfer("t1", 0));
      await repo.finishTransfer("t1", state: TransferState.failed, bytes: 10, at: _at(1));
      await repo.updateTransferProgress("t1", bytes: 99, at: _at(9));

      final TransferRecord t = (await repo.recentTransfers()).single;
      expect(t.state, TransferState.failed);
      expect(t.bytes, 10);
    });

    test("running ones come first, then newest first", () async {
      await repo.beginTransfer(_transfer("old-done", 0));
      await repo.finishTransfer("old-done", state: TransferState.completed, bytes: 1, at: _at(1));
      await repo.beginTransfer(_transfer("running-early", 5));
      await repo.beginTransfer(_transfer("new-done", 20));
      await repo.finishTransfer("new-done", state: TransferState.completed, bytes: 1, at: _at(21));
      await repo.beginTransfer(_transfer("running-late", 30));

      expect((await repo.recentTransfers()).map((TransferRecord t) => t.id), <String>[
        "running-late",
        "running-early",
        "new-done",
        "old-done",
      ]);
      expect((await repo.recentTransfers(limit: 3)).length, 3);
    });

    test("whatever a dead server left running is marked interrupted", () async {
      await repo.beginTransfer(_transfer("a", 0));
      await repo.beginTransfer(_transfer("b", 1));
      await repo.beginTransfer(_transfer("done", 2));
      await repo.finishTransfer("done", state: TransferState.completed, bytes: 1, at: _at(3));

      expect(await repo.interruptRunningTransfers(_at(60)), 2);

      final Map<String, TransferRecord> byId = <String, TransferRecord>{
        for (final TransferRecord t in await repo.recentTransfers()) t.id: t,
      };
      expect(byId["a"]!.state, TransferState.interrupted);
      expect(byId["b"]!.finishedAt!.toUtc(), _at(60));
      expect(byId["done"]!.state, TransferState.completed);
      expect(await repo.interruptRunningTransfers(_at(61)), 0);
    });

    test("an unknown total gives no fraction", () async {
      await repo.beginTransfer(_transfer("t1", 0));
      await repo.updateTransferProgress("t1", bytes: 5, at: _at(1));

      expect((await repo.recentTransfers()).single.fraction, isNull);
    });
  });

  group("clients", () {
    ClientRecord client(String actor, String address, int first, int last, {AccessVia via = AccessVia.web}) =>
        ClientRecord(actor: actor, address: address, via: via, firstSeenAt: _at(first), lastSeenAt: _at(last));

    test("the first sighting is kept, the last one moves on", () async {
      await repo.touchClient(client("bob", "10.0.0.2", 0, 0));
      await repo.touchClient(client("bob", "10.0.0.2", 100, 100, via: AccessVia.webdav));

      final ClientRecord c = (await repo.recentClients(since: _at(-1))).single;
      expect(c.firstSeenAt.toUtc(), _at(0));
      expect(c.lastSeenAt.toUtc(), _at(100));
      expect(c.via, AccessVia.webdav);
    });

    test("one person on two addresses is two clients, most recent first, and old ones drop out", () async {
      await repo.touchClient(client("bob", "10.0.0.2", 0, 10));
      await repo.touchClient(client("bob", "10.0.0.3", 0, 50));
      await repo.touchClient(client("ann", "10.0.0.4", 0, 5));

      final List<ClientRecord> recent = await repo.recentClients(since: _at(8));
      expect(recent.map((ClientRecord c) => c.key), <String>["bob|10.0.0.3", "bob|10.0.0.2"]);
    });
  });

  group("housekeeping", () {
    test("prune drops what is older than the cut-off", () async {
      await repo.addEvent(_event("old", 0));
      await repo.addEvent(_event("new", 100));
      await repo.beginTransfer(_transfer("old-t", 0));
      await repo.finishTransfer("old-t", state: TransferState.completed, bytes: 1, at: _at(1));
      await repo.beginTransfer(_transfer("new-t", 100));
      await repo.touchClient(ClientRecord(actor: "a", address: "x", via: AccessVia.web, firstSeenAt: _at(0), lastSeenAt: _at(0)));

      await repo.prune(before: _at(50));

      expect((await repo.recentEvents()).map((ActivityEvent e) => e.id), <String>["new"]);
      expect((await repo.recentTransfers()).map((TransferRecord t) => t.id), <String>["new-t"]);
      expect(await repo.recentClients(since: _at(-100)), isEmpty);
    });

    test("prune keeps only the newest N, and never a running transfer", () async {
      for (int i = 0; i < 5; i++) {
        await repo.addEvent(_event("e$i", 100 + i));
      }
      await repo.beginTransfer(_transfer("running", 100));
      for (int i = 0; i < 4; i++) {
        await repo.beginTransfer(_transfer("t$i", 200 + i));
        await repo.finishTransfer("t$i", state: TransferState.completed, bytes: 1, at: _at(300 + i));
      }

      await repo.prune(before: _at(0), keepEvents: 2, keepTransfers: 2);

      expect((await repo.recentEvents()).map((ActivityEvent e) => e.id), <String>["e4", "e3"]);
      final List<String> transfers = (await repo.recentTransfers()).map((TransferRecord t) => t.id).toList();
      expect(transfers, contains("running"));
      expect(transfers, containsAll(<String>["t3", "t2"]));
      expect(transfers, isNot(contains("t0")));
    });

    test("clear forgets everything", () async {
      await repo.addEvent(_event("e", 0));
      await repo.beginTransfer(_transfer("t", 0));
      await repo.touchClient(ClientRecord(actor: "a", address: "x", via: AccessVia.web, firstSeenAt: _at(0), lastSeenAt: _at(0)));

      await repo.clear();

      expect(await repo.recentEvents(), isEmpty);
      expect(await repo.recentTransfers(), isEmpty);
      expect(await repo.recentClients(since: _at(-100)), isEmpty);
    });
  });
}
