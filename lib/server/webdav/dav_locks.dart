import "package:uuid/uuid.dart";

import "../../domain/repositories/clock.dart";
import "dav_xml.dart";

/// One WebDAV write lock.
final class DavLock {
  const DavLock({
    required this.token,
    required this.accountId,
    required this.resourceKey,
    required this.depthInfinity,
    required this.scope,
    required this.owner,
    required this.expiresAt,
    required this.timeout,
  });

  /// `opaquelocktoken:<uuid>` — what the client sends back to prove it holds it.
  final String token;
  final String accountId;

  /// `<rootId>/<path>`, see [DavLockManager.keyFor].
  final String resourceKey;

  /// Covers everything below a collection as well.
  final bool depthInfinity;
  final DavLockScope scope;
  final String owner;
  final DateTime expiresAt;
  final Duration timeout;

  DavLock refreshed(DateTime expiresAt, Duration timeout) => DavLock(
    token: token,
    accountId: accountId,
    resourceKey: resourceKey,
    depthInfinity: depthInfinity,
    scope: scope,
    owner: owner,
    expiresAt: expiresAt,
    timeout: timeout,
  );
}

/// In-memory WebDAV locks (RFC 4918 class 2).
///
/// Clients such as macOS Finder and Microsoft Office insist on LOCK before they
/// write; without it Finder mounts the share read-only. Locks are advisory glue
/// between well-behaved clients — the real safety (atomic writes, the Recycle
/// Bin) lives in the storage layer — so they are kept small, in memory, bounded,
/// and expire on their own. A lock can only be used by the account that made it,
/// and only by someone who presents its token.
final class DavLockManager {
  DavLockManager({
    required Clock clock,
    this.maxLocks = 1000,
    this.defaultTimeout = const Duration(minutes: 10),
    this.maxTimeout = const Duration(hours: 1),
    Uuid? uuid,
  }) : _clock = clock,
       _uuid = uuid ?? const Uuid();

  final Clock _clock;
  final Uuid _uuid;
  final int maxLocks;
  final Duration defaultTimeout;
  final Duration maxTimeout;

  final Map<String, DavLock> _locks = <String, DavLock>{};

  int get length {
    _purge();
    return _locks.length;
  }

  /// The lock key for a resource: root id plus its normalized path.
  static String keyFor(String rootId, String normalizedPath) => "$rootId$normalizedPath";

  /// Creates a lock, or `null` if it conflicts with a lock someone else holds
  /// (or the manager is full).
  DavLock? create({
    required String accountId,
    required String resourceKey,
    required bool depthInfinity,
    required DavLockScope scope,
    required String owner,
    Duration? requested,
  }) {
    _purge();
    if (_locks.length >= maxLocks) return null;

    for (final DavLock existing in _locks.values) {
      final bool overlaps =
          _covers(existing, resourceKey) || (depthInfinity && _isBelow(existing.resourceKey, resourceKey));
      if (!overlaps) continue;
      if (existing.scope == DavLockScope.exclusive || scope == DavLockScope.exclusive) return null;
    }

    final Duration timeout = _clamp(requested);
    final DavLock lock = DavLock(
      token: "opaquelocktoken:${_uuid.v4()}",
      accountId: accountId,
      resourceKey: resourceKey,
      depthInfinity: depthInfinity,
      scope: scope,
      owner: owner,
      expiresAt: _clock.now().add(timeout),
      timeout: timeout,
    );
    _locks[lock.token] = lock;
    return lock;
  }

  /// Extends a lock the account holds; `null` if it is unknown, expired or someone else's.
  DavLock? refresh(String token, String accountId, {Duration? requested}) {
    _purge();
    final DavLock? lock = _locks[token];
    if (lock == null || lock.accountId != accountId) return null;
    final Duration timeout = _clamp(requested);
    final DavLock renewed = lock.refreshed(_clock.now().add(timeout), timeout);
    _locks[token] = renewed;
    return renewed;
  }

  /// Releases a lock the account holds.
  bool unlock(String token, String accountId) {
    _purge();
    final DavLock? lock = _locks[token];
    if (lock == null || lock.accountId != accountId) return false;
    _locks.remove(token);
    return true;
  }

  /// The locks that apply to [resourceKey] (directly, or inherited from a
  /// depth-infinity lock on a parent).
  List<DavLock> locksOn(String resourceKey) {
    _purge();
    return <DavLock>[
      for (final DavLock lock in _locks.values)
        if (_covers(lock, resourceKey)) lock,
    ];
  }

  /// Whether [accountId] may modify [resourceKey], given the lock tokens the
  /// request presented. With [includeDescendants] locks below it count too
  /// (deleting or moving a folder disturbs everything inside).
  bool mayModify(
    String accountId,
    String resourceKey,
    Set<String> presented, {
    bool includeDescendants = false,
  }) {
    _purge();
    for (final DavLock lock in _locks.values) {
      final bool relevant =
          _covers(lock, resourceKey) || (includeDescendants && _isBelow(lock.resourceKey, resourceKey));
      if (!relevant) continue;
      if (lock.accountId != accountId || !presented.contains(lock.token)) return false;
    }
    return true;
  }

  /// Tokens named anywhere in an `If:` header (`(<opaquelocktoken:…>)`).
  static Set<String> tokensIn(String? ifHeader) {
    if (ifHeader == null) return const <String>{};
    return <String>{
      for (final RegExpMatch m in RegExp(r"opaquelocktoken:[0-9A-Za-z-]+").allMatches(ifHeader)) m.group(0)!,
    };
  }

  Duration _clamp(Duration? requested) {
    if (requested == null) return defaultTimeout;
    if (requested > maxTimeout) return maxTimeout;
    if (requested < const Duration(seconds: 1)) return defaultTimeout;
    return requested;
  }

  /// Parses `Timeout: Second-600, Infinite`; "Infinite" is capped like any other.
  static Duration? parseTimeout(String? header) {
    if (header == null) return null;
    for (final String part in header.split(",")) {
      final String value = part.trim();
      if (value.toLowerCase() == "infinite") return const Duration(days: 1);
      final RegExpMatch? match = RegExp(r"^Second-(\d+)$", caseSensitive: false).firstMatch(value);
      if (match != null) {
        final int? seconds = int.tryParse(match.group(1)!);
        if (seconds != null) return Duration(seconds: seconds);
      }
    }
    return null;
  }

  bool _covers(DavLock lock, String key) =>
      lock.resourceKey == key || (lock.depthInfinity && _isBelow(key, lock.resourceKey));

  /// [key] is strictly inside [ancestor].
  static bool _isBelow(String key, String ancestor) {
    final String prefix = ancestor.endsWith("/") ? ancestor : "$ancestor/";
    return key != ancestor && key.startsWith(prefix);
  }

  void _purge() {
    final DateTime now = _clock.now();
    _locks.removeWhere((String _, DavLock lock) => !now.isBefore(lock.expiresAt));
  }
}
