import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/ftp_settings.dart";

/// Same shape as `AppPreferences` (see `test/data/settings_repository_test.dart`):
/// a small `toMap`/`fromMap` entity where the important property is that
/// damaged storage can never start the server in a surprising mode.
void main() {
  group("FtpSettings", () {
    test("defaults are off, explicit FTPS, port 2121, passive 50000-50050", () {
      const FtpSettings settings = FtpSettings();

      expect(settings.enabled, isFalse);
      expect(settings.mode, FtpMode.explicitTls);
      expect(settings.port, 2121);
      expect(settings.passiveStart, 50000);
      expect(settings.passiveEnd, 50050);
      expect(settings.usesTls, isTrue);
    });

    test("plain mode is the only one that doesn't use TLS", () {
      expect(const FtpSettings(mode: FtpMode.plain).usesTls, isFalse);
      expect(const FtpSettings(mode: FtpMode.explicitTls).usesTls, isTrue);
      expect(const FtpSettings(mode: FtpMode.implicitTls).usesTls, isTrue);
    });

    test("copyWith changes one field and keeps the rest", () {
      const FtpSettings base = FtpSettings(enabled: true, port: 3000);

      final FtpSettings next = base.copyWith(mode: FtpMode.implicitTls);

      expect(next.enabled, isTrue);
      expect(next.port, 3000);
      expect(next.mode, FtpMode.implicitTls);
    });

    test("what is saved comes back the same", () {
      const FtpSettings chosen = FtpSettings(
        enabled: true,
        mode: FtpMode.implicitTls,
        port: 2200,
        passiveStart: 40000,
        passiveEnd: 40100,
      );

      final FtpSettings back = FtpSettings.fromMap(chosen.toMap());

      expect(back.enabled, isTrue);
      expect(back.mode, FtpMode.implicitTls);
      expect(back.port, 2200);
      expect(back.passiveStart, 40000);
      expect(back.passiveEnd, 40100);
    });

    test("an empty store gives the defaults", () {
      final FtpSettings settings = FtpSettings.fromMap(const <String, String>{});

      expect(settings.enabled, isFalse);
      expect(settings.mode, FtpMode.explicitTls);
      expect(settings.port, 2121);
      expect(settings.passiveStart, 50000);
      expect(settings.passiveEnd, 50050);
    });

    test("an unrecognised mode falls back to explicit TLS instead of crashing", () {
      final FtpSettings settings = FtpSettings.fromMap(const <String, String>{"ftp.mode": "carrier-pigeon"});

      expect(settings.mode, FtpMode.explicitTls);
    });

    test("a corrupt port falls back to the default", () {
      final FtpSettings settings = FtpSettings.fromMap(const <String, String>{"ftp.port": "not a number"});

      expect(settings.port, 2121);
    });

    test("a port outside 1024-65535 falls back to the default rather than being honoured", () {
      final FtpSettings settings = FtpSettings.fromMap(const <String, String>{"ftp.port": "80"});

      expect(settings.port, 2121);
    });

    test("a corrupt passive range falls back to the default range (both ends, not just the bad one)", () {
      final FtpSettings settings = FtpSettings.fromMap(const <String, String>{
        "ftp.pasvStart": "not a number",
        "ftp.pasvEnd": "50050",
      });

      expect(settings.passiveStart, 50000);
      expect(settings.passiveEnd, 50050);
    });

    test("a passive range that is too small falls back to the default range", () {
      final FtpSettings settings = FtpSettings.fromMap(const <String, String>{
        "ftp.pasvStart": "50000",
        "ftp.pasvEnd": "50003",
      });

      expect(settings.passiveStart, 50000);
      expect(settings.passiveEnd, 50050);
    });

    test("only the literal string 'true' turns enabled on", () {
      expect(FtpSettings.fromMap(const <String, String>{"ftp.enabled": "yes"}).enabled, isFalse);
      expect(FtpSettings.fromMap(const <String, String>{"ftp.enabled": "1"}).enabled, isFalse);
      expect(FtpSettings.fromMap(const <String, String>{"ftp.enabled": "true"}).enabled, isTrue);
    });
  });

  group("FtpSettings.validatePort", () {
    test("accepts the boundary values", () {
      expect(FtpSettings.validatePort(1024), isNull);
      expect(FtpSettings.validatePort(65535), isNull);
    });

    test("rejects out of range or missing", () {
      expect(FtpSettings.validatePort(1023), isNotNull);
      expect(FtpSettings.validatePort(65536), isNotNull);
      expect(FtpSettings.validatePort(null), isNotNull);
    });
  });

  group("FtpSettings.validatePassiveRange", () {
    test("accepts a range of at least 10 ports within bounds", () {
      expect(FtpSettings.validatePassiveRange(50000, 50050), isNull);
      expect(FtpSettings.validatePassiveRange(1024, 1033), isNull, reason: "exactly 10 ports");
    });

    test("rejects a reversed range", () {
      expect(FtpSettings.validatePassiveRange(50050, 50000), isNotNull);
    });

    test("rejects a range with fewer than 10 ports", () {
      expect(FtpSettings.validatePassiveRange(50000, 50005), isNotNull);
    });

    test("rejects a range wider than 1000 ports", () {
      expect(FtpSettings.validatePassiveRange(1024, 1024 + 1001), isNotNull);
    });

    test("rejects missing bounds", () {
      expect(FtpSettings.validatePassiveRange(null, 50050), isNotNull);
      expect(FtpSettings.validatePassiveRange(50000, null), isNotNull);
    });

    test("rejects bounds outside 1024-65535", () {
      expect(FtpSettings.validatePassiveRange(1000, 2000), isNotNull);
      expect(FtpSettings.validatePassiveRange(60000, 70000), isNotNull);
    });
  });
}
