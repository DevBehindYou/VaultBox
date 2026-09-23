import "../entities/share.dart";

/// Persistence for share and upload-request links (only token HASHES).
abstract interface class ShareRepository {
  Future<void> add(Share share);

  Future<Share?> get(String id);

  /// [tokenHash] is `ShareTokens.hash(token)`.
  Future<Share?> findByTokenHash(String tokenHash);

  /// Newest first.
  Future<List<Share>> list();

  Future<void> delete(String id);

  /// Removes everything an account created (when the account is deleted).
  Future<void> deleteByCreator(String accountId);

  /// Counts one use (a download, or an uploaded file) — but only if the link is
  /// still active at [now] and under its limit, in ONE atomic step so two
  /// racing requests can't both take the last use. Returns whether it counted.
  Future<bool> tryUse(String id, DateTime now);
}
