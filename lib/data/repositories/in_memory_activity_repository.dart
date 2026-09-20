import "../../domain/entities/activity.dart";
import "../../domain/repositories/activity_repository.dart";

/// Test fake for [ActivityRepository] — same contract as the Drift one, no database.
final class InMemoryActivityRepository implements ActivityRepository {
  final List<ActivityEvent> _events = <ActivityEvent>[];
  final List<TransferRecord> _transfers = <TransferRecord>[];
  final Map<String, ClientRecord> _clients = <String, ClientRecord>{};

  @override
  Future<void> addEvent(ActivityEvent event) async {
    _events.add(event);
  }

  @override
  Future<List<ActivityEvent>> recentEvents({int limit = 200}) async {
    // Newest first; events written in the same instant keep newest-written first.
    final List<int> order = List<int>.generate(_events.length, (int i) => i)
      ..sort((int a, int b) {
        final int byTime = _events[b].at.compareTo(_events[a].at);
        return byTime != 0 ? byTime : b.compareTo(a);
      });
    return <ActivityEvent>[for (final int i in order.take(limit)) _events[i]];
  }

  @override
  Future<void> beginTransfer(TransferRecord transfer) async {
    _transfers.add(transfer);
  }

  @override
  Future<void> updateTransferProgress(String id, {required int bytes, required DateTime at}) async {
    _replace(id, (TransferRecord t) => t.isRunning ? t.copyWith(bytes: bytes, updatedAt: at) : t);
  }

  @override
  Future<void> finishTransfer(
    String id, {
    required TransferState state,
    required int bytes,
    required DateTime at,
  }) async {
    _replace(id, (TransferRecord t) => t.copyWith(bytes: bytes, updatedAt: at, finishedAt: at, state: state));
  }

  @override
  Future<List<TransferRecord>> recentTransfers({int limit = 200}) async {
    final List<int> order = List<int>.generate(_transfers.length, (int i) => i)
      ..sort((int a, int b) {
        final TransferRecord left = _transfers[a];
        final TransferRecord right = _transfers[b];
        if (left.isRunning != right.isRunning) return left.isRunning ? -1 : 1;
        final int byTime = right.startedAt.compareTo(left.startedAt);
        return byTime != 0 ? byTime : b.compareTo(a);
      });
    return <TransferRecord>[for (final int i in order.take(limit)) _transfers[i]];
  }

  @override
  Future<void> touchClient(ClientRecord client) async {
    final ClientRecord? known = _clients[client.key];
    _clients[client.key] = ClientRecord(
      actor: client.actor,
      address: client.address,
      via: client.via,
      firstSeenAt: known?.firstSeenAt ?? client.firstSeenAt,
      lastSeenAt: client.lastSeenAt,
    );
  }

  @override
  Future<List<ClientRecord>> recentClients({required DateTime since}) async {
    return _clients.values.where((ClientRecord c) => !c.lastSeenAt.isBefore(since)).toList()
      ..sort((ClientRecord a, ClientRecord b) => b.lastSeenAt.compareTo(a.lastSeenAt));
  }

  @override
  Future<int> interruptRunningTransfers(DateTime at) async {
    int count = 0;
    for (int i = 0; i < _transfers.length; i++) {
      if (!_transfers[i].isRunning) continue;
      _transfers[i] = _transfers[i].copyWith(updatedAt: at, finishedAt: at, state: TransferState.interrupted);
      count++;
    }
    return count;
  }

  @override
  Future<void> prune({required DateTime before, int keepEvents = 1000, int keepTransfers = 500}) async {
    _events.removeWhere((ActivityEvent e) => e.at.isBefore(before));
    if (_events.length > keepEvents) _events.removeRange(0, _events.length - keepEvents);

    _transfers.removeWhere((TransferRecord t) => !t.isRunning && t.startedAt.isBefore(before));
    // Only the newest [keepTransfers] stay; a running transfer is never pruned.
    final List<TransferRecord> newestFirst = List<TransferRecord>.of(_transfers)
      ..sort((TransferRecord a, TransferRecord b) => b.startedAt.compareTo(a.startedAt));
    final Set<String> drop = <String>{
      for (final TransferRecord t in newestFirst.skip(keepTransfers))
        if (!t.isRunning) t.id,
    };
    _transfers.removeWhere((TransferRecord t) => drop.contains(t.id));

    _clients.removeWhere((String _, ClientRecord c) => c.lastSeenAt.isBefore(before));
  }

  @override
  Future<void> clear() async {
    _events.clear();
    _transfers.clear();
    _clients.clear();
  }

  void _replace(String id, TransferRecord Function(TransferRecord old) change) {
    final int index = _transfers.indexWhere((TransferRecord t) => t.id == id);
    if (index == -1) return;
    _transfers[index] = change(_transfers[index]);
  }
}
