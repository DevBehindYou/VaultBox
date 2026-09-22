import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/access_rule.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/ftp_settings.dart";
import "package:vaultbox/domain/entities/recycle_item.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/server/ftp/ftp_deps.dart";

import "../../helpers/ftp_harness.dart";

/// FTP over a real `dart:io` `Socket`, against an [FtpServer] bound to
/// 127.0.0.1 with in-memory storage — exactly as a real client sees it.
///
/// Plain FTP (`FtpMode.plain`) is used throughout except in `ftp_tls_test.dart`:
/// it needs no certificate and no `AUTH TLS` dance, so these tests can focus
/// on the command/data-connection behaviour itself.
void main() {
  Future<FtpTestClient> connectClient(int port, {InternetAddress? sourceAddress}) async {
    final FtpTestClient client = await FtpTestClient.connect(port, sourceAddress: sourceAddress);
    final List<String> banner = await client.readReply();
    expect(FtpTestClient.codeOf(banner), 220);
    return client;
  }

  Future<FtpTestClient> loginAsAdmin(int port) async {
    final FtpTestClient client = await connectClient(port);
    expect(FtpTestClient.codeOf(await client.send("USER admin")), 331);
    expect(FtpTestClient.codeOf(await client.send("PASS ${FtpHarness.adminPassword}")), 230);
    return client;
  }

  /// Opens a PASV data connection and returns it, leaving the control
  /// connection ready for the transfer command that will use it.
  Future<Socket> openDataConnection(FtpTestClient client, {InternetAddress? sourceAddress}) async {
    final List<String> reply = await client.send("PASV");
    expect(FtpTestClient.codeOf(reply), 227);
    final RegExpMatch match = RegExp(r"\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)").firstMatch(reply.first)!;
    final int p1 = int.parse(match.group(5)!);
    final int p2 = int.parse(match.group(6)!);
    final int port = p1 * 256 + p2;
    final Socket socket = await Socket.connect(InternetAddress.loopbackIPv4, port, sourceAddress: sourceAddress);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return socket;
  }

  group("login", () {
    late FtpHarness harness;
    late int port;

    setUp(() async {
      harness = FtpHarness(settings: const FtpSettings(enabled: true, mode: FtpMode.plain));
      port = await harness.start();
    });

    tearDown(() => harness.stop());

    test("the right username and password signs in", () async {
      final FtpTestClient client = await connectClient(port);
      expect(FtpTestClient.codeOf(await client.send("USER admin")), 331);
      expect(FtpTestClient.codeOf(await client.send("PASS ${FtpHarness.adminPassword}")), 230);
      await client.close();
    });

    test("a wrong password is refused without saying whether the username exists", () async {
      final FtpTestClient client = await connectClient(port);
      expect(FtpTestClient.codeOf(await client.send("USER nobody")), 331);
      expect(FtpTestClient.codeOf(await client.send("PASS whatever")), 530);
      await client.close();
    });

    test("commands other than login are refused before signing in", () async {
      final FtpTestClient client = await connectClient(port);
      expect(FtpTestClient.codeOf(await client.send("PWD")), 530);
      await client.close();
    });

    test("three wrong passwords in a row lock and close the connection", () async {
      final FtpTestClient client = await connectClient(port);

      for (int i = 0; i < 2; i++) {
        expect(FtpTestClient.codeOf(await client.send("USER admin")), 331);
        expect(FtpTestClient.codeOf(await client.send("PASS wrong")), 530);
      }
      expect(FtpTestClient.codeOf(await client.send("USER admin")), 331);
      expect(FtpTestClient.codeOf(await client.send("PASS wrong")), 421);

      // the server has hung up: the next read reaches end-of-stream, not a hang
      expect(await client.readReply(), isEmpty);
      await client.close();
    });
  });

  group("navigation and listings", () {
    late FtpHarness harness;
    late int port;
    late FtpTestClient client;

    setUp(() async {
      harness = FtpHarness(settings: const FtpSettings(enabled: true, mode: FtpMode.plain));
      port = await harness.start();
      client = await loginAsAdmin(port);
    });

    tearDown(() async {
      await client.close();
      await harness.stop();
    });

    test("PWD starts at the top, CWD enters a storage location, CDUP leaves it", () async {
      expect((await client.send("PWD")).first, contains('"/"'));

      expect(FtpTestClient.codeOf(await client.send("CWD Phone")), 250);
      expect((await client.send("PWD")).first, contains('"/Phone"'));

      expect(FtpTestClient.codeOf(await client.send("CDUP")), 250);
      expect((await client.send("PWD")).first, contains('"/"'));
    });

    test("CWD into an unknown storage location fails", () async {
      expect(FtpTestClient.codeOf(await client.send("CWD Nope")), 550);
    });

    test("LIST at the top shows the storage locations", () async {
      final Socket data = await openDataConnection(client);
      final List<String> announce = await client.send("LIST");
      expect(FtpTestClient.codeOf(announce), 150);
      final String body = await utf8.decoder.bind(data).join();
      expect(FtpTestClient.codeOf(await client.readReply()), 226);

      expect(body, contains(" Phone"));
      expect(body, contains(" Card"));
    });

    test("LIST inside a folder shows its files, MLSD gives machine-readable facts, NLST gives bare names", () async {
      await client.send("CWD Phone");

      final Socket listData = await openDataConnection(client);
      await client.send("LIST");
      final String listBody = await utf8.decoder.bind(listData).join();
      await client.readReply();
      expect(listBody, contains("readme.txt"));
      expect(listBody, contains("docs"));
      final List<String> listLines = listBody.split("\r\n").where((String l) => l.isNotEmpty).toList();
      expect(listLines.any((String l) => l.startsWith("d")), isTrue, reason: "docs is a directory");
      expect(listLines.any((String l) => l.startsWith("-")), isTrue, reason: "readme.txt is a file");

      final Socket mlsdData = await openDataConnection(client);
      await client.send("MLSD");
      final String mlsdBody = await utf8.decoder.bind(mlsdData).join();
      await client.readReply();
      expect(mlsdBody, contains("type=file;"));
      expect(mlsdBody, contains("type=dir;"));
      expect(mlsdBody, contains(" readme.txt"));

      final Socket nlstData = await openDataConnection(client);
      await client.send("NLST");
      final String nlstBody = await utf8.decoder.bind(nlstData).join();
      await client.readReply();
      expect(nlstBody.split("\r\n").where((String l) => l.isNotEmpty), containsAll(<String>["readme.txt", "docs"]));
      expect(nlstBody, isNot(contains("type=")), reason: "NLST is names only, not MLSD facts");
    });
  });

  group("transfers", () {
    late FtpHarness harness;
    late int port;
    late FtpTestClient client;

    setUp(() async {
      harness = FtpHarness(settings: const FtpSettings(enabled: true, mode: FtpMode.plain));
      port = await harness.start();
      client = await loginAsAdmin(port);
      await client.send("CWD Phone");
    });

    tearDown(() async {
      await client.close();
      await harness.stop();
    });

    test("RETR downloads a whole file", () async {
      final Socket data = await openDataConnection(client);
      final List<String> announce = await client.send("RETR readme.txt");
      expect(FtpTestClient.codeOf(announce), 150);
      final String body = await utf8.decoder.bind(data).join();
      expect(FtpTestClient.codeOf(await client.readReply()), 226);
      expect(body, "hello world");
    });

    test("REST then RETR resumes from a byte offset", () async {
      expect(FtpTestClient.codeOf(await client.send("REST 6")), 350);
      final Socket data = await openDataConnection(client);
      final List<String> announce = await client.send("RETR readme.txt");
      expect(FtpTestClient.codeOf(announce), 150);
      final String body = await utf8.decoder.bind(data).join();
      await client.readReply();
      expect(body, "world");
    });

    test("RETR on a missing file fails before ever touching a data connection", () async {
      final List<String> announce = await client.send("RETR nope.txt");
      expect(FtpTestClient.codeOf(announce), 550);
    });

    test("STOR uploads a new file, which SIZE then confirms", () async {
      final Socket data = await openDataConnection(client);
      final List<String> announce = await client.send("STOR newfile.txt");
      expect(FtpTestClient.codeOf(announce), 150);
      data.add(utf8.encode("uploaded content"));
      await data.flush();
      await data.close();
      expect(FtpTestClient.codeOf(await client.readReply()), 226);

      final List<String> size = await client.send("SIZE newfile.txt");
      expect(FtpTestClient.codeOf(size), 213);
      expect(size.first, contains("16"), reason: '"uploaded content" is 16 bytes');
    });

    test("STOR onto a read-only storage location is refused", () async {
      await client.send("CDUP");
      await client.send("CWD Card");
      final Socket data = await openDataConnection(client);
      final List<String> announce = await client.send("STOR nope.txt");
      expect(FtpTestClient.codeOf(announce), 550);
      data.destroy();
    });
  });

  group("making and removing things", () {
    late FtpHarness harness;
    late int port;
    late FtpTestClient client;

    setUp(() async {
      harness = FtpHarness(settings: const FtpSettings(enabled: true, mode: FtpMode.plain));
      port = await harness.start();
      client = await loginAsAdmin(port);
      await client.send("CWD Phone");
    });

    tearDown(() async {
      await client.close();
      await harness.stop();
    });

    test("MKD creates a folder that can then be entered", () async {
      expect(FtpTestClient.codeOf(await client.send("MKD NewFolder")), 257);
      expect(FtpTestClient.codeOf(await client.send("CWD NewFolder")), 250);
    });

    test("MKD refuses a name that already exists", () async {
      expect(FtpTestClient.codeOf(await client.send("MKD docs")), 550);
    });

    test("RMD moves a folder to the Recycle Bin, not straight to oblivion", () async {
      await client.send("MKD ToRemove");

      final List<String> rmd = await client.send("RMD ToRemove");
      expect(FtpTestClient.codeOf(rmd), 250);
      expect(rmd.first, contains("Recycle Bin"));

      expect(FtpTestClient.codeOf(await client.send("CWD ToRemove")), 550, reason: "it's gone from the live listing");
      expect(
        (await harness.recycleBin.listItems("r1")).any((RecycleItem item) => item.originalName == "ToRemove"),
        isTrue,
      );
    });

    test("DELE moves a file to the Recycle Bin", () async {
      final List<String> dele = await client.send("DELE docs/a.txt");
      expect(FtpTestClient.codeOf(dele), 250);
      expect(dele.first, contains("Recycle Bin"));

      final StorageStat stat = await harness.phone.stat(StoragePath.parseDecoded("r1", "/docs/a.txt"));
      expect(stat.exists, isFalse, reason: "the live copy is gone");
      expect(
        (await harness.recycleBin.listItems("r1")).any((RecycleItem item) => item.originalName == "a.txt"),
        isTrue,
      );
    });

    test("DELE on a folder is refused: use RMD", () async {
      expect(FtpTestClient.codeOf(await client.send("DELE docs")), 550);
    });

    test("RNFR then RNTO renames within the same folder", () async {
      expect(FtpTestClient.codeOf(await client.send("RNFR docs/a.txt")), 350);
      expect(FtpTestClient.codeOf(await client.send("RNTO docs/b.txt")), 250);

      expect(FtpTestClient.codeOf(await client.send("SIZE docs/a.txt")), 550);
      expect(FtpTestClient.codeOf(await client.send("SIZE docs/b.txt")), 213);
    });

    test("RNTO without a prior RNFR is refused", () async {
      expect(FtpTestClient.codeOf(await client.send("RNTO docs/x.txt")), 503);
    });
  });

  group("permissions", () {
    late FtpHarness harness;
    late int port;

    setUp(() async {
      harness = FtpHarness(
        settings: const FtpSettings(enabled: true, mode: FtpMode.plain),
        authorizer: const AclAuthorizer(),
        extraAccounts: <Account>[
          Account(
            id: "m1",
            username: "member",
            passwordHash: "fake:member pass",
            createdAt: DateTime.utc(2026, 9, 20),
            role: AccountRole.member,
            rules: const <AccessRule>[
              AccessRule(id: "rule1", accountId: "m1", rootId: "r1", pathPrefix: "/docs", permissions: AccessRule.readOnly),
            ],
          ),
        ],
      );
      port = await harness.start();
    });

    tearDown(() => harness.stop());

    Future<FtpTestClient> loginAsMember() async {
      final FtpTestClient client = await connectClient(port);
      expect(FtpTestClient.codeOf(await client.send("USER member")), 331);
      expect(FtpTestClient.codeOf(await client.send("PASS member pass")), 230);
      return client;
    }

    test("a member can read inside their granted folder", () async {
      final FtpTestClient client = await loginAsMember();
      expect(FtpTestClient.codeOf(await client.send("CWD Phone")), 250);
      expect(FtpTestClient.codeOf(await client.send("CWD docs")), 250);
      expect(FtpTestClient.codeOf(await client.send("SIZE a.txt")), 213);
      await client.close();
    });

    test("a member is refused outside their granted folder", () async {
      final FtpTestClient client = await loginAsMember();
      await client.send("CWD Phone");
      expect(FtpTestClient.codeOf(await client.send("SIZE readme.txt")), 550);
      await client.close();
    });

    test("a member with only read may not write inside their own granted folder", () async {
      final FtpTestClient client = await loginAsMember();
      await client.send("CWD Phone");
      await client.send("CWD docs");
      final List<String> mkd = await client.send("MKD sub");
      expect(FtpTestClient.codeOf(mkd), 550);
      await client.close();
    });
  });

  group("active mode and data-connection safety", () {
    late FtpHarness harness;
    late int port;
    late FtpTestClient client;

    setUp(() async {
      harness = FtpHarness(settings: const FtpSettings(enabled: true, mode: FtpMode.plain));
      port = await harness.start();
      client = await loginAsAdmin(port);
    });

    tearDown(() async {
      await client.close();
      await harness.stop();
    });

    test("PORT is refused: this server is passive-only", () async {
      expect(FtpTestClient.codeOf(await client.send("PORT 127,0,0,1,12,34")), 502);
    });

    test("EPRT is refused for the same reason", () async {
      expect(FtpTestClient.codeOf(await client.send("EPRT |1|127.0.0.1|1234|")), 502);
    });

    test("a data connection from a different address than the control connection is refused", () async {
      await client.send("CWD Phone");
      final Socket wrongAddress = await openDataConnection(client, sourceAddress: InternetAddress("127.0.0.2"));

      final List<String> announce = await client.send("RETR readme.txt");
      expect(FtpTestClient.codeOf(announce), 150, reason: "the announcement goes out before the mismatch is noticed");
      final List<String> rejected = await client.readReply();
      expect(FtpTestClient.codeOf(rejected), 425);

      wrongAddress.destroy();
    });
  });

  group("connection limits", () {
    test("a connection past the total limit is not accepted as a session", () async {
      final FtpHarness harness = FtpHarness(
        settings: const FtpSettings(enabled: true, mode: FtpMode.plain),
        limits: const FtpLimits(failedLoginDelay: Duration.zero, maxConnections: 2, maxConnectionsPerAddress: 10),
      );
      final int port = await harness.start();

      final FtpTestClient c1 = await connectClient(port);
      final FtpTestClient c2 = await connectClient(port);
      expect(harness.server.connectionCount, 2);

      final Socket extra = await Socket.connect(InternetAddress.loopbackIPv4, port);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(harness.server.connectionCount, 2, reason: "the third connection must be refused, not added");
      extra.destroy();

      await c1.close();
      await c2.close();
      await harness.stop();
    });

    test("a connection past the per-address limit is refused even with total capacity to spare", () async {
      final FtpHarness harness = FtpHarness(
        settings: const FtpSettings(enabled: true, mode: FtpMode.plain),
        limits: const FtpLimits(failedLoginDelay: Duration.zero, maxConnections: 10, maxConnectionsPerAddress: 1),
        // Two different simulated source addresses in this test, so the
        // "private/loopback clients only" filter (which historically only
        // ever needs to recognise 127.0.0.1 in production) must not get in
        // the way of exercising the per-address counter itself.
        privateClientsOnly: false,
      );
      final int port = await harness.start();

      final FtpTestClient c1 = await connectClient(port);
      expect(harness.server.connectionCount, 1);

      final Socket sameAddressExtra = await Socket.connect(InternetAddress.loopbackIPv4, port);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(harness.server.connectionCount, 1, reason: "127.0.0.1 is already at its own limit of 1");
      sameAddressExtra.destroy();

      final FtpTestClient c2 = await connectClient(port, sourceAddress: InternetAddress("127.0.0.2"));
      expect(harness.server.connectionCount, 2, reason: "a different address has its own, separate counter");

      await c1.close();
      await c2.close();
      await harness.stop();
    });
  });
}
