import "../../domain/entities/share.dart";
import "../../domain/repositories/share_repository.dart";

/// Test fake for [ShareRepository] — same contract as the Drift one.
final class InMemoryShareRepository implements ShareRepository {
  InMemoryShareRepository([List<Share> initial = const <Share>[]]) {
    _shares.addAll(initial);
  }

  final List<Share> _shares = <Share>[];

  @override
  Future<void> add(Share share) async {
    if (_shares.any((Share s) => s.id == share.id || s.tokenHash == share.tokenHash)) {
      throw StateError("duplicate share");
    }
    _shares.add(share);
  }

  @override
  Future<Share?> get(String id) async {
    for (final Share share in _shares) {
      if (share.id == id) return share;
    }
    return null;
  }

  @override
  Future<Share?> findByTokenHash(String tokenHash) async {
    for (final Share share in _shares) {
      if (share.tokenHash == tokenHash) return share;
    }
    return null;
  }

  @override
  Future<List<Share>> list() async {
    final List<Share> newestFirst = List<Share>.of(_shares)
      ..sort((Share a, Share b) => b.createdAt.compareTo(a.createdAt));
    return newestFirst;
  }

  @override
  Future<void> delete(String id) async {
    _shares.removeWhere((Share s) => s.id == id);
  }

  @override
  Future<void> deleteByCreator(String accountId) async {
    _shares.removeWhere((Share s) => s.createdBy == accountId);
  }

  @override
  Future<bool> tryUse(String id, DateTime now) async {
    final int index = _shares.indexWhere((Share s) => s.id == id);
    if (index == -1 || !_shares[index].isActive(now)) return false;
    _shares[index] = _shares[index].copyWith(useCount: _shares[index].useCount + 1);
    return true;
  }
}
