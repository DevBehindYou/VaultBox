import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/activity.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/domain/usecases/create_share.dart";
import "package:vaultbox/server/api/api_types.dart";

import "../helpers/api_harness.dart";

/// What the server writes into the Activity history as people use it — and,
/// as important, what it never writes.
void main() {
  late ApiHarness h;

  setUp(() {
    h = ApiHarness();
    h.backend
      ..seedFile("/a.txt", utf8.encode("0123456789"))
      ..seedDirectory("/Inbox");
  });

  Future<List<ActivityEvent>> events() async {
    await h.activity.flush();
    return h.activityRepository.recentEvents();
  }

  Future<List<TransferRecord>> transfers() async {
    await h.activity.flush();
    return h.activityRepository.recentTransfers();
  }

  Future<List<ClientRecord>> clients() async {
    await h.activity.flush();
    return h.activityRepository.recentClients(since: h.clock.now().subtract(const Duration(days: 1)));
  }

  group("signing in", () {
    test("a sign-in is noted with who and from where, and the person shows up as a client", () async {
      await h.login();

      final ActivityEvent signedIn = (await events()).single;
      expect(signedIn.kind, ActivityKind.signedIn);
      expect(signedIn.actor, "admin");
      expect(signedIn.address, "192.168.1.10");
      expect(signedIn.severity, ActivitySeverity.info);

      final ClientRecord client = (await clients()).single;
      expect(client.actor, "admin");
      expect(client.via, AccessVia.web);
    });

    test("a refused sign-in is a warning that does not repeat the name that was typed", () async {
      final ApiResponse response = await h.send(
        "POST",
        "/api/v1/auth/login",
        json: <String, Object?>{"username": "hunter2-typed-by-mistake", "password": "wrong password"},
      );
      expect(response.status, 401);

      final ActivityEvent refused = (await events()).single;
      expect(refused.kind, ActivityKind.signInRefused);
      expect(refused.severity, ActivitySeverity.warning);
      expect(refused.address, "192.168.1.10");
      expect(refused.actor, isNull);
      expect(refused.message, isNot(contains("hunter2")));
      expect(refused.message, isNot(contains("wrong password")));
    });

    test("a burst of refused sign-ins is one entry, not thousands", () async {
      for (int i = 0; i < 4; i++) {
        await h.send(
          "POST",
          "/api/v1/auth/login",
          json: <String, Object?>{"username": "admin", "password": "wrong $i"},
        );
      }

      expect((await events()).where((ActivityEvent e) => e.kind == ActivityKind.signInRefused), hasLength(1));
    });

    test("being locked out is noted once for the address", () async {
      for (int i = 0; i < 8; i++) {
        await h.send(
          "POST",
          "/api/v1/auth/login",
          json: <String, Object?>{"username": "admin", "password": "wrong $i"},
        );
        h.clock.advance(const Duration(seconds: 11)); // past the per-refusal window each time
      }

      final List<ActivityEvent> locked = (await events())
          .where((ActivityEvent e) => e.message.contains("delayed"))
          .toList();
      expect(locked, hasLength(1));
    });

    test("signing out is noted", () async {
      final String token = await h.login();
      await h.send("POST", "/api/v1/auth/logout", token: token);

      expect((await events()).map((ActivityEvent e) => e.kind), contains(ActivityKind.signedOut));
    });

    test("no event ever contains the password", () async {
      final String token = await h.login();
      await h.send("POST", "/api/v1/auth/logout", token: token);
      await h.send(
        "POST",
        "/api/v1/auth/login",
        json: <String, Object?>{"username": "admin", "password": "not the password"},
      );

      for (final ActivityEvent e in await events()) {
        expect(e.message, isNot(contains(ApiHarness.password)));
        expect(e.message, isNot(contains("not the password")));
        expect(e.message, isNot(contains(token)));
      }
    });
  });

  group("files", () {
    late String token;

    setUp(() async => token = await h.login());

    Future<ApiResponse> download({Map<String, String>? headers, String method = "GET"}) => h.send(
      method,
      "/api/v1/roots/r1/content",
      token: token,
      query: <String, String>{"path": "/a.txt"},
      headers: headers ?? const <String, String>{},
    );

    test("a download is a transfer: who, what, how big, and done once it has been read", () async {
      final ApiResponse response = await download();
      expect(await ApiHarness.bodyBytes(response), utf8.encode("0123456789"));

      final TransferRecord t = (await transfers()).single;
      expect(t.direction, TransferDirection.download);
      expect(t.via, AccessVia.web);
      expect(t.actor, "admin");
      expect(t.name, "a.txt");
      expect(t.totalBytes, 10);
      expect(t.bytes, 10);
      expect(t.state, TransferState.completed);
    });

    test("only the file's name is kept, never where it lives", () async {
      await ApiHarness.bodyBytes(await download());

      final TransferRecord t = (await transfers()).single;
      expect(t.name, isNot(contains("/")));
      expect(t.name, isNot(contains(ApiHarness.secretUri)));
    });

    test("a download the client walks away from is interrupted", () async {
      final ApiResponse response = await download();
      final Stream<List<int>> stream = response.stream!;
      await stream.first; // reads a chunk, then the subscription is cancelled

      final TransferRecord t = (await transfers()).single;
      expect(t.state, TransferState.interrupted);
    });

    test("a HEAD request and a resumed range are not new downloads", () async {
      await download(method: "HEAD");
      await ApiHarness.bodyBytes(await download(headers: <String, String>{"range": "bytes=5-"}));

      expect(await transfers(), isEmpty);
    });

    test("a range from the start still counts as the download", () async {
      await ApiHarness.bodyBytes(await download(headers: <String, String>{"range": "bytes=0-3"}));

      final TransferRecord t = (await transfers()).single;
      expect(t.state, TransferState.completed);
      expect(t.bytes, 4);
    });

    test("an upload is a transfer too", () async {
      final ApiResponse response = await h.send(
        "PUT",
        "/api/v1/roots/r1/content",
        token: token,
        query: <String, String>{"path": "/new.txt"},
        bytes: utf8.encode("hello!"),
      );
      expect(response.status, 201);

      final TransferRecord t = (await transfers()).single;
      expect(t.direction, TransferDirection.upload);
      expect(t.name, "new.txt");
      expect(t.bytes, 6);
      expect(t.totalBytes, 6);
      expect(t.state, TransferState.completed);
    });

    test("an upload that breaks off is interrupted and leaves no file", () async {
      Stream<List<int>> broken() async* {
        yield utf8.encode("par");
        throw StateError("connection reset");
      }

      final ApiResponse response = await h.send(
        "PUT",
        "/api/v1/roots/r1/content",
        token: token,
        query: <String, String>{"path": "/partial.txt"},
        stream: broken(),
      );
      expect(response.status, 400);

      final TransferRecord t = (await transfers()).single;
      expect(t.state, TransferState.interrupted);
      expect(t.bytes, 3);
    });

    test("an upload the phone refuses is a failed transfer", () async {
      final ApiResponse response = await h.send(
        "PUT",
        "/api/v1/roots/r1/content",
        token: token,
        query: <String, String>{"path": "/a.txt"}, // exists, no overwrite=1
        bytes: utf8.encode("x"),
      );
      expect(response.status, 409);

      final TransferRecord t = (await transfers()).single;
      expect(t.state, TransferState.failed);
    });
  });

  group("share links", () {
    test("someone downloading through a link is noted as a link user, not as an account", () async {
      final CreatedShare link = await h.makeShare(path: "/a.txt");

      final ApiResponse response = await h.send("GET", "/api/v1/public/${link.token}/content");
      expect(await ApiHarness.bodyBytes(response), utf8.encode("0123456789"));

      final List<ActivityEvent> log = await events();
      expect(log.single.kind, ActivityKind.linkUsed);
      expect(log.single.message, contains("a.txt"));
      expect(log.single.message, isNot(contains(link.token)));

      final TransferRecord t = (await transfers()).single;
      expect(t.via, AccessVia.link);
      expect(t.actor, "Link");
      expect(t.state, TransferState.completed);
    });

    test("the link's secret never reaches the history", () async {
      final CreatedShare link = await h.makeShare(path: "/a.txt");
      await ApiHarness.bodyBytes(await h.send("GET", "/api/v1/public/${link.token}/content"));

      for (final ActivityEvent e in await events()) {
        expect(jsonEncode(<String, Object?>{"m": e.message, "a": e.address, "u": e.actor}), isNot(contains(link.token)));
      }
      for (final TransferRecord t in await transfers()) {
        expect("${t.name}|${t.actor}", isNot(contains(link.token)));
      }
    });

    test("a wrong link password is a warning, once per minute-ish, and not the password", () async {
      final CreatedShare link = await h.makeShare(path: "/a.txt", password: "hunter22");

      final ApiResponse response = await h.send(
        "POST",
        "/api/v1/public/${link.token}/unlock",
        json: <String, Object?>{"password": "guess-one"},
      );
      expect(response.status, 401);

      final ActivityEvent e = (await events()).single;
      expect(e.severity, ActivitySeverity.warning);
      expect(e.message, isNot(contains("guess-one")));
      expect(e.message, isNot(contains("hunter22")));
    });

    test("files sent through an upload link are noted", () async {
      final CreatedShare link = await h.makeShare(kind: ShareKind.upload, path: "/Inbox");

      final ApiResponse response = await h.send(
        "PUT",
        "/api/v1/public/${link.token}/content",
        query: <String, String>{"name": "hello.txt"},
        bytes: utf8.encode("hi there"),
      );
      expect(response.status, 201);

      final TransferRecord t = (await transfers()).single;
      expect(t.direction, TransferDirection.upload);
      expect(t.via, AccessVia.link);
      expect(t.name, "hello.txt");
      expect(t.bytes, 8);
      expect(t.state, TransferState.completed);
      expect((await events()).single.message, contains("hello.txt"));
    });

    test("an upload over the size limit is a failed transfer, not a completed one", () async {
      final CreatedShare link = await h.makeShare(kind: ShareKind.upload, path: "/Inbox", maxFileBytes: 4);

      final ApiResponse response = await h.send(
        "PUT",
        "/api/v1/public/${link.token}/content",
        query: <String, String>{"name": "big.txt"},
        stream: Stream<List<int>>.fromIterable(<List<int>>[utf8.encode("12"), utf8.encode("345"), utf8.encode("6")]),
      );
      expect(response.status, 413);

      final TransferRecord t = (await transfers()).single;
      expect(t.state, isNot(TransferState.completed));
      expect((await events()).where((ActivityEvent e) => e.message.contains("big.txt")), isEmpty);
    });
  });
}
