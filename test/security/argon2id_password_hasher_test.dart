import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/security/argon2id_password_hasher.dart";

/// Tiny cost parameters so the suite is fast; production defaults are OWASP's
/// (19 MiB, 2 iterations) and are only checked structurally here.
void main() {
  Argon2idPasswordHasher hasher({int memory = 64, int iterations = 1, bool isolate = false}) =>
      Argon2idPasswordHasher(memoryKiB: memory, iterations: iterations, useIsolate: isolate);

  test("hash is self-describing PHC-style and salted", () async {
    final Argon2idPasswordHasher h = hasher();
    final String a = await h.hash("correct horse battery");
    final String b = await h.hash("correct horse battery");

    expect(a, startsWith(r"$argon2id$v=19$m=64,t=1,p=1$"));
    expect(a.split(r"$"), hasLength(6));
    expect(a, isNot(b), reason: "a fresh random salt per hash");
    expect(a, isNot(contains("correct horse battery")));
  });

  test("verifies the right password and rejects wrong ones", () async {
    final Argon2idPasswordHasher h = hasher();
    final String encoded = await h.hash("correct horse battery");

    expect(await h.verify("correct horse battery", encoded), isTrue);
    expect(await h.verify("correct horse batterY", encoded), isFalse);
    expect(await h.verify("", encoded), isFalse);
  });

  test("a tampered digest does not verify", () async {
    final Argon2idPasswordHasher h = hasher();
    final String encoded = await h.hash("correct horse battery");
    final List<String> parts = encoded.split(r"$");
    parts[5] = parts[5].substring(0, parts[5].length - 2) + (parts[5].endsWith("AA") ? "BB" : "AA");

    expect(await h.verify("correct horse battery", parts.join(r"$")), isFalse);
  });

  test("malformed or implausible hashes fail closed (never throw)", () async {
    final Argon2idPasswordHasher h = hasher();
    for (final String bad in <String>[
      "",
      "plaintext",
      r"$argon2id$v=19$m=64,t=1,p=1$c2FsdHNhbHQ",
      r"$argon2i$v=19$m=64,t=1,p=1$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaGhhc2g",
      r"$argon2id$v=18$m=64,t=1,p=1$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaGhhc2g",
      r"$argon2id$v=19$m=x,t=1,p=1$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaGhhc2g",
      r"$argon2id$v=19$m=64,t=1$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaGhhc2g",
      r"$argon2id$v=19$m=64,t=1,p=1$***$***",
      // Hostile parameters must be refused BEFORE any work is done:
      r"$argon2id$v=19$m=999999999,t=1,p=1$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaGhhc2g",
      r"$argon2id$v=19$m=64,t=99999,p=1$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaGhhc2g",
      r"$argon2id$v=19$m=64,t=1,p=99$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaGhhc2g",
    ]) {
      expect(await h.verify("whatever", bad), isFalse, reason: "must reject: $bad");
    }
  });

  test("needsRehash: weaker parameters or garbage => true; current => false", () async {
    final String weak = await hasher(memory: 64, iterations: 1).hash("pw-for-testing-1");
    final Argon2idPasswordHasher stronger = hasher(memory: 128, iterations: 2);
    final String current = await stronger.hash("pw-for-testing-1");

    expect(stronger.needsRehash(weak), isTrue);
    expect(stronger.needsRehash(current), isFalse);
    expect(stronger.needsRehash("garbage"), isTrue);
  });

  test("an old, weaker hash still verifies under a stronger hasher", () async {
    final String old = await hasher(memory: 64, iterations: 1).hash("pw-for-testing-1");
    expect(await hasher(memory: 128, iterations: 2).verify("pw-for-testing-1", old), isTrue);
  });

  test("works when derivation runs in a separate isolate", () async {
    final Argon2idPasswordHasher h = hasher(isolate: true);
    final String encoded = await h.hash("isolate-password-1");
    expect(await h.verify("isolate-password-1", encoded), isTrue);
    expect(await h.verify("isolate-password-2", encoded), isFalse);
  });

  test("production defaults are OWASP's minimum", () async {
    final String encoded = await Argon2idPasswordHasher(useIsolate: false, memoryKiB: 19456, iterations: 2)
        .hash("defaults-check-pw");
    expect(encoded, startsWith(r"$argon2id$v=19$m=19456,t=2,p=1$"));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
