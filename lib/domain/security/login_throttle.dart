import "dart:math";

import "../repositories/clock.dart";

/// Slows down password guessing. Key it by something the attacker can't rotate
/// for free (e.g. `"$remoteAddress|$lowercasedUsername"`) and — important — also
/// for usernames that DON'T exist, so response behaviour doesn't reveal which
/// accounts are real.
///
/// After [freeAttempts] failures the key is locked for [baseLock], doubling with
/// each further failure up to [maxLock]. A success clears the key; a key that
/// has been quiet for [forgetAfter] is forgotten. Callers must check
/// [lockedFor] BEFORE verifying a password.
final class LoginThrottle {
  LoginThrottle({
    required Clock clock,
    this.freeAttempts = 5,
    this.baseLock = const Duration(seconds: 30),
    this.maxLock = const Duration(minutes: 15),
    this.forgetAfter = const Duration(hours: 1),
    this.maxTrackedKeys = 10000,
  }) : _clock = clock;

  final Clock _clock;
  final int freeAttempts;
  final Duration baseLock;
  final Duration maxLock;
  final Duration forgetAfter;
  final int maxTrackedKeys;

  final Map<String, _Record> _records = <String, _Record>{};

  /// How much longer [key] is locked out, or `null` if it may try now.
  Duration? lockedFor(String key) {
    final _Record? record = _records[key];
    if (record == null) return null;
    final DateTime now = _clock.now();
    if (now.difference(record.lastFailure) > forgetAfter) {
      _records.remove(key);
      return null;
    }
    final DateTime? until = record.lockedUntil;
    if (until != null && now.isBefore(until)) return until.difference(now);
    return null;
  }

  void recordFailure(String key) {
    final DateTime now = _clock.now();
    _Record? record = _records[key];
    if (record != null && now.difference(record.lastFailure) > forgetAfter) record = null;
    record ??= _Record();

    record.failures++;
    record.lastFailure = now;
    if (record.failures >= freeAttempts) {
      final int doublings = min(record.failures - freeAttempts, 20);
      final int millis = min(baseLock.inMilliseconds * (1 << doublings), maxLock.inMilliseconds);
      record.lockedUntil = now.add(Duration(milliseconds: millis));
    }

    _records.remove(key); // re-insert so the map stays ordered oldest -> newest
    _records[key] = record;
    if (_records.length > maxTrackedKeys) _records.remove(_records.keys.first);
  }

  void recordSuccess(String key) => _records.remove(key);
}

final class _Record {
  int failures = 0;
  DateTime lastFailure = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? lockedUntil;
}
