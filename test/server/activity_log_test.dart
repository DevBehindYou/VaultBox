import "dart:async";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/repositories/in_memory_activity_repository.dart";
import "package:vaultbox/domain/entities/activity.dart";
import "package:vaultbox/domain/repositories/activity_repository.dart";
import "package:vaultbox/domain/repositories/id_generator.dart";
import "package:vaultbox/server/activity/activity_log.dart";
import "package:vaultbox/server/files/storage_gate.dart";

import "../helpers/fake_clock.dart";

final class _Ids implements IdGenerator {
  int _next = 0;

  @override
  String newId() => "id${_next++}";
}

void main() {
  late FakeClock clock;
  late InMemoryActivityRepository repo;
  late ActivityLog log;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 9, 20, 12));
    repo = InMemoryActivityRepository();
    log = ActivityLog(repository: repo, clock: clock, ids: _Ids());
  });

  TransferMeter meter({TransferDirection direction = TransferDirection.download, int? total}) => log.transfer(
    direction: direction,
    via: AccessVia.web,
    actor: "admin",
    name: "a.bin",
    totalBytes: total,
  );

  Future<TransferRecord> theTransfer() async {
    await log.flush();
    return (await repo.recentTransfers()).single;
  }

  group("events", () {
    test("are recorded with who, where from and how serious", () async {
      log.event(
        ActivityKind.signInRefused,
        "A sign-in was refused.",
        severity: ActivitySeverity.warning,
        actor: "bob",
        address: "10.0.0.2",
      );
      await log.flush();

      final ActivityEvent event = (await repo.recentEvents()).single;
      expect(event.kind, ActivityKind.signInRefused);
      expect(event.severity, ActivitySeverity.warning);
      expect(event.message, "A sign-in was refused.");
      expect(event.actor, "bob");
      expect(event.address, "10.0.0.2");
      expect(event.at, clock.now());
    });

    test("one that can be repeated is kept once per window", () async {
      void refused() => log.event(
        ActivityKind.signInRefused,
        "refused",
        throttleKey: "refused|10.0.0.2",
        throttleFor: const Duration(seconds: 10),
      );

      refused();
      refused();
      clock.advance(const Duration(seconds: 5));
      refused();
      await log.flush();
      expect(await repo.recentEvents(), hasLength(1));

      clock.advance(const Duration(seconds: 6));
      refused();
      await log.flush();
      expect(await repo.recentEvents(), hasLength(2));
    });

    test("different throttle keys don't silence each other", () async {
      log.event(ActivityKind.signInRefused, "a", throttleKey: "a");
      log.event(ActivityKind.signInRefused, "b", throttleKey: "b");
      await log.flush();

      expect(await repo.recentEvents(), hasLength(2));
    });
  });

  group("clients", () {
    test("a client is noted once, then refreshed at most every 30 seconds", () async {
      final DateTime start = clock.now();
      log.seen(actor: "bob", address: "10.0.0.2", via: AccessVia.web);
      clock.advance(const Duration(seconds: 10));
      log.seen(actor: "bob", address: "10.0.0.2", via: AccessVia.web);
      await log.flush();
      expect((await repo.recentClients(since: start.subtract(const Duration(days: 1)))).single.lastSeenAt, start);

      clock.advance(const Duration(seconds: 30));
      log.seen(actor: "bob", address: "10.0.0.2", via: AccessVia.webdav);
      await log.flush();
      final ClientRecord bob = (await repo.recentClients(since: start.subtract(const Duration(days: 1)))).single;
      expect(bob.lastSeenAt, clock.now());
      expect(bob.firstSeenAt, start);
      expect(bob.via, AccessVia.webdav);
    });
  });

  group("a download", () {
    test("is completed when its stream ends, with the bytes counted", () async {
      final TransferMeter m = meter(total: 6);
      final List<int> received = <int>[];

      await m
          .watchDownload(Stream<List<int>>.fromIterable(<List<int>>[<int>[1, 2, 3], <int>[4, 5, 6]]))
          .forEach(received.addAll);

      expect(received, <int>[1, 2, 3, 4, 5, 6], reason: "the bytes pass through untouched");
      final TransferRecord t = await theTransfer();
      expect(t.state, TransferState.completed);
      expect(t.bytes, 6);
      expect(t.totalBytes, 6);
      expect(t.name, "a.bin");
      expect(t.actor, "admin");
      expect(t.finishedAt, isNotNull);
    });

    test("failed when the file can't be read to the end", () async {
      final TransferMeter m = meter();
      Stream<List<int>> broken() async* {
        yield <int>[1, 2];
        throw StateError("disk went away");
      }

      await expectLater(m.watchDownload(broken()).drain<void>(), throwsStateError);

      final TransferRecord t = await theTransfer();
      expect(t.state, TransferState.failed);
      expect(t.bytes, 2);
    });

    test("interrupted when the client stops listening before the end", () async {
      final StreamController<List<int>> source = StreamController<List<int>>();
      addTearDown(source.close);
      final StreamSubscription<List<int>> subscription = meter(total: 100).watchDownload(source.stream).listen((_) {});

      source.add(<int>[1, 2, 3]);
      await pumpEventQueue();
      await subscription.cancel();

      final TransferRecord t = await theTransfer();
      expect(t.state, TransferState.interrupted);
      expect(t.bytes, 3);
    });

    test("progress is written at most once a second, and the end always is", () async {
      final StreamController<List<int>> source = StreamController<List<int>>();
      addTearDown(source.close);
      final StreamSubscription<List<int>> subscription = meter(total: 100).watchDownload(source.stream).listen((_) {});

      source.add(<int>[1, 2, 3]); // first chunk: written
      await pumpEventQueue();
      source.add(<int>[4, 5, 6]); // same instant: not written
      await pumpEventQueue();
      await log.flush();
      expect((await repo.recentTransfers()).single.bytes, 3);

      clock.advance(const Duration(seconds: 2));
      source.add(<int>[7, 8, 9]); // a second later: written
      await pumpEventQueue();
      await log.flush();
      expect((await repo.recentTransfers()).single.bytes, 9);

      await subscription.cancel();
    });

    test("is settled once: a later finish changes nothing", () async {
      final TransferMeter m = meter();
      await m.watchDownload(Stream<List<int>>.value(<int>[1])).drain<void>();
      m.finish(TransferState.failed);

      expect((await theTransfer()).state, TransferState.completed);
    });
  });

  group("an upload", () {
    Future<int> receiveAll(Stream<List<int>> counted) async {
      final List<int> all = <int>[];
      await counted.forEach(all.addAll);
      return all.length;
    }

    test("is completed once it was received, and returns what receive returned", () async {
      final TransferMeter m = meter(direction: TransferDirection.upload, total: 4);

      final int length = await m.upload(Stream<List<int>>.value(<int>[1, 2, 3, 4]), receiveAll);

      expect(length, 4);
      final TransferRecord t = await theTransfer();
      expect(t.direction, TransferDirection.upload);
      expect(t.state, TransferState.completed);
      expect(t.bytes, 4);
    });

    test("that broke off on the sender's side is interrupted, and the error still surfaces", () async {
      final TransferMeter m = meter(direction: TransferDirection.upload);

      await expectLater(
        m.upload(
          Stream<List<int>>.value(<int>[1, 2]),
          (Stream<List<int>> counted) async {
            await counted.drain<void>();
            throw const StorageFault(FaultKind.interrupted);
          },
        ),
        throwsA(isA<StorageFault>()),
      );

      final TransferRecord t = await theTransfer();
      expect(t.state, TransferState.interrupted);
      expect(t.bytes, 2);
    });

    test("that failed on the phone's side is failed", () async {
      final TransferMeter m = meter(direction: TransferDirection.upload);

      await expectLater(
        m.upload(Stream<List<int>>.value(<int>[1]), (Stream<List<int>> counted) async => throw StateError("disk full")),
        throwsStateError,
      );

      expect((await theTransfer()).state, TransferState.failed);
    });
  });

  group("stateForError", () {
    test("a sender that went away is interrupted, anything else failed", () {
      expect(stateForError(const StorageFault(FaultKind.interrupted)), TransferState.interrupted);
      expect(stateForError(const StorageFault(FaultKind.forbidden)), TransferState.failed);
      expect(stateForError(StateError("x")), TransferState.failed);
    });
  });

  group("when the server starts", () {
    test("leftovers are closed, old history dropped, and the start noted", () async {
      final DateTime now = clock.now();
      await repo.addEvent(
        ActivityEvent(
          id: "old",
          at: now.subtract(const Duration(days: 60)),
          kind: ActivityKind.signedIn,
          message: "old",
        ),
      );
      await repo.beginTransfer(
        TransferRecord(
          id: "left-running",
          direction: TransferDirection.download,
          via: AccessVia.web,
          actor: "admin",
          name: "x",
          startedAt: now.subtract(const Duration(hours: 1)),
          updatedAt: now.subtract(const Duration(hours: 1)),
        ),
      );

      log.serverStarted();
      await log.flush();

      expect((await repo.recentTransfers()).single.state, TransferState.interrupted);
      final List<ActivityEvent> events = await repo.recentEvents();
      expect(events.map((ActivityEvent e) => e.id), isNot(contains("old")));
      expect(events.single.kind, ActivityKind.serverStarted);
    });
  });

  group("ActivityLog.none()", () {
    test("records nothing but never gets in the way", () async {
      final ActivityLog none = ActivityLog.none();
      expect(none.isRecording, isFalse);

      none.event(ActivityKind.signedIn, "x");
      none.seen(actor: "a", address: "b", via: AccessVia.web);
      none.serverStarted();
      final TransferMeter m = none.transfer(
        direction: TransferDirection.download,
        via: AccessVia.web,
        actor: "a",
        name: "n",
      );
      final List<int> received = <int>[];
      await m.watchDownload(Stream<List<int>>.value(<int>[1, 2])).forEach(received.addAll);
      final int uploaded = await m.upload(Stream<List<int>>.value(<int>[1, 2, 3]), (Stream<List<int>> s) async {
        int n = 0;
        await s.forEach((List<int> c) => n += c.length);
        return n;
      });
      await none.flush();

      expect(received, <int>[1, 2]);
      expect(uploaded, 3);
      expect(await repo.recentEvents(), isEmpty, reason: "the real log's repository is untouched");
    });
  });

  test("a repository that fails costs history, never the request", () async {
    final ActivityLog broken = ActivityLog(repository: _BrokenRepository(), clock: clock, ids: _Ids());

    broken.event(ActivityKind.signedIn, "x");
    final TransferMeter m = broken.transfer(
      direction: TransferDirection.download,
      via: AccessVia.web,
      actor: "a",
      name: "n",
    );
    final List<int> received = <int>[];
    await m.watchDownload(Stream<List<int>>.value(<int>[1, 2, 3])).forEach(received.addAll);

    await expectLater(broken.flush(), completes);
    expect(received, <int>[1, 2, 3]);
  });
}

/// Every write fails, like a full disk or a locked database.
final class _BrokenRepository implements ActivityRepository {
  Future<T> _fail<T>() => Future<T>.error(StateError("db locked"));

  @override
  Future<void> addEvent(ActivityEvent event) => _fail<void>();

  @override
  Future<List<ActivityEvent>> recentEvents({int limit = 200}) => _fail<List<ActivityEvent>>();

  @override
  Future<void> beginTransfer(TransferRecord transfer) => _fail<void>();

  @override
  Future<void> updateTransferProgress(String id, {required int bytes, required DateTime at}) => _fail<void>();

  @override
  Future<void> finishTransfer(
    String id, {
    required TransferState state,
    required int bytes,
    required DateTime at,
  }) => _fail<void>();

  @override
  Future<List<TransferRecord>> recentTransfers({int limit = 200}) => _fail<List<TransferRecord>>();

  @override
  Future<void> touchClient(ClientRecord client) => _fail<void>();

  @override
  Future<List<ClientRecord>> recentClients({required DateTime since}) => _fail<List<ClientRecord>>();

  @override
  Future<int> interruptRunningTransfers(DateTime at) => _fail<int>();

  @override
  Future<void> prune({required DateTime before, int keepEvents = 1000, int keepTransfers = 500}) => _fail<void>();

  @override
  Future<void> clear() => _fail<void>();
}
