import "../entities/activity.dart";

/// What happened on the server, kept so the app can show it later.
///
/// The server runs in its own engine and the app in another, so this is the one
/// place they meet: the server writes, the app reads (by polling).
abstract interface class ActivityRepository {
  Future<void> addEvent(ActivityEvent event);

  /// Newest first.
  Future<List<ActivityEvent>> recentEvents({int limit = 200});

  Future<void> beginTransfer(TransferRecord transfer);

  Future<void> updateTransferProgress(String id, {required int bytes, required DateTime at});

  Future<void> finishTransfer(String id, {required TransferState state, required int bytes, required DateTime at});

  /// Running ones first, then newest first.
  Future<List<TransferRecord>> recentTransfers({int limit = 200});

  /// Records that [ClientRecord.key] was seen. The first sighting is kept as
  /// [ClientRecord.firstSeenAt].
  Future<void> touchClient(ClientRecord client);

  /// Clients seen at or after [since], most recent first.
  Future<List<ClientRecord>> recentClients({required DateTime since});

  /// Anything still marked running belongs to a server that is gone: mark it
  /// interrupted. Returns how many there were.
  Future<int> interruptRunningTransfers(DateTime at);

  /// Drops what is older than [before] and anything beyond the newest
  /// [keepEvents] events / [keepTransfers] transfers.
  Future<void> prune({required DateTime before, int keepEvents = 1000, int keepTransfers = 500});

  /// Forgets everything (events, transfers and clients).
  Future<void> clear();
}
