import "dart:convert";
import "dart:isolate";
import "dart:math";

import "package:cryptography/cryptography.dart";

import "../../domain/security/password_hasher.dart";

/// Argon2id password hasher (pure Dart, `package:cryptography`).
///
/// Defaults are OWASP's minimum for Argon2id: 19 MiB memory, 2 iterations, 1
/// lane. Pure Dart is slower than native, so each derivation runs in its own
/// isolate ([useIsolate]) and never blocks the server's event loop.
///
/// Encoding is PHC-style: `$argon2id$v=19$m=<KiB>,t=<iters>,p=<lanes>$<salt>$<hash>`
/// (unpadded base64), so parameters can be raised later and old hashes still
/// verify.
final class Argon2idPasswordHasher implements PasswordHasher {
  Argon2idPasswordHasher({
    this.memoryKiB = 19456,
    this.iterations = 2,
    this.parallelism = 1,
    this.useIsolate = true,
    Random? random,
  }) : _random = random ?? Random.secure();

  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final bool useIsolate;
  final Random _random;

  static const int _saltBytes = 16;
  static const int _hashBytes = 32;

  // Ceilings applied when VERIFYING, so a corrupted or hostile stored string
  // can't make us allocate gigabytes or spin for minutes.
  static const int _maxMemoryKiB = 262144; // 256 MiB
  static const int _maxIterations = 10;
  static const int _maxParallelism = 4;

  @override
  Future<String> hash(String password) async {
    final List<int> salt = List<int>.generate(_saltBytes, (_) => _random.nextInt(256));
    final List<int> digest = await _derive(
      password, salt, memoryKiB, iterations, parallelism, _hashBytes, useIsolate,
    );
    return <String>[
      "",
      "argon2id",
      "v=19",
      "m=$memoryKiB,t=$iterations,p=$parallelism",
      _encode(salt),
      _encode(digest),
    ].join(r"$");
  }

  @override
  Future<bool> verify(String password, String encoded) async {
    final _Parsed? parsed = _parse(encoded);
    if (parsed == null) return false;
    final List<int> actual = await _derive(
      password, parsed.salt, parsed.memoryKiB, parsed.iterations, parsed.parallelism,
      parsed.digest.length, useIsolate,
    );
    return _constantTimeEquals(actual, parsed.digest);
  }

  @override
  bool needsRehash(String encoded) {
    final _Parsed? parsed = _parse(encoded);
    if (parsed == null) return true;
    return parsed.memoryKiB < memoryKiB || parsed.iterations < iterations;
  }

  static Future<List<int>> _derive(
    String password,
    List<int> salt,
    int memoryKiB,
    int iterations,
    int parallelism,
    int length,
    bool useIsolate,
  ) {
    // Only primitives and lists cross the isolate boundary.
    if (!useIsolate) {
      return _deriveInline(password, salt, memoryKiB, iterations, parallelism, length);
    }
    return Isolate.run(
      () => _deriveInline(password, salt, memoryKiB, iterations, parallelism, length),
    );
  }

  static Future<List<int>> _deriveInline(
    String password,
    List<int> salt,
    int memoryKiB,
    int iterations,
    int parallelism,
    int length,
  ) async {
    final Argon2id algorithm = Argon2id(
      memory: memoryKiB,
      parallelism: parallelism,
      iterations: iterations,
      hashLength: length,
    );
    final SecretKey key = await algorithm.deriveKeyFromPassword(password: password, nonce: salt);
    return key.extractBytes();
  }

  static _Parsed? _parse(String encoded) {
    final List<String> parts = encoded.split(r"$");
    if (parts.length != 6 || parts[0].isNotEmpty) return null;
    if (parts[1] != "argon2id" || parts[2] != "v=19") return null;

    int? memory;
    int? iterations;
    int? lanes;
    for (final String pair in parts[3].split(",")) {
      final List<String> kv = pair.split("=");
      if (kv.length != 2) return null;
      final int? value = int.tryParse(kv[1]);
      if (value == null) return null;
      switch (kv[0]) {
        case "m":
          memory = value;
        case "t":
          iterations = value;
        case "p":
          lanes = value;
        default:
          return null;
      }
    }
    if (memory == null || iterations == null || lanes == null) return null;
    if (lanes < 1 || lanes > _maxParallelism) return null;
    if (iterations < 1 || iterations > _maxIterations) return null;
    if (memory < 8 * lanes || memory > _maxMemoryKiB) return null;

    try {
      final List<int> salt = base64.decode(base64.normalize(parts[4]));
      final List<int> digest = base64.decode(base64.normalize(parts[5]));
      if (salt.length < 8 || salt.length > 64) return null;
      if (digest.length < 16 || digest.length > 64) return null;
      return _Parsed(memory, iterations, lanes, salt, digest);
    } on FormatException {
      return null;
    }
  }

  static String _encode(List<int> bytes) => base64.encode(bytes).replaceAll("=", "");

  /// Compares without returning early, so timing doesn't reveal how many leading
  /// bytes matched.
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int difference = 0;
    for (int i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}

final class _Parsed {
  const _Parsed(this.memoryKiB, this.iterations, this.parallelism, this.salt, this.digest);

  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final List<int> salt;
  final List<int> digest;
}
