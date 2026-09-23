import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/server/webdav/dav_locks.dart";
import "package:vaultbox/server/webdav/dav_xml.dart";

import "../helpers/fake_clock.dart";

List<int> _b(String s) => utf8.encode(s);

void main() {
  group("xmlEscape", () {
    test("escapes the five characters that matter", () {
      expect(xmlEscape('a & b < c > d "e"'), "a &amp; b &lt; c &gt; d &quot;e&quot;");
      expect(xmlEscape("plain"), "plain");
    });
  });

  group("parsePropfind", () {
    test("an empty body is allprop", () {
      expect(parsePropfind(<int>[]).mode, PropfindMode.allprop);
      expect(parsePropfind(_b("  \n ")).mode, PropfindMode.allprop);
    });

    test("allprop and propname", () {
      expect(parsePropfind(_b('<propfind xmlns="DAV:"><allprop/></propfind>')).mode, PropfindMode.allprop);
      expect(parsePropfind(_b('<D:propfind xmlns:D="DAV:"><D:propname/></D:propfind>')).mode, PropfindMode.propname);
    });

    test("prop lists names with their namespaces, whatever the prefix", () {
      final PropfindRequest request = parsePropfind(
        _b(
          '<a:propfind xmlns:a="DAV:" xmlns:m="urn:schemas-microsoft-com:"><a:prop>'
          "<a:getcontentlength/><m:Win32FileAttributes/><unqualified/></a:prop></a:propfind>",
        ),
      );

      expect(request.mode, PropfindMode.prop);
      expect(request.props, <DavProp>[
        const DavProp.dav("getcontentlength"),
        const DavProp("urn:schemas-microsoft-com:", "Win32FileAttributes"),
        const DavProp("", "unqualified"),
      ]);
    });

    test("a default namespace declared higher up applies", () {
      final PropfindRequest request = parsePropfind(_b('<propfind xmlns="DAV:"><prop><displayname/></prop></propfind>'));
      expect(request.props, <DavProp>[const DavProp.dav("displayname")]);
    });

    test("wrong root, wrong namespace, no children and broken XML are rejected", () {
      for (final String bad in <String>[
        "<foo/>",
        '<propfind xmlns="urn:other"><allprop/></propfind>',
        '<propfind xmlns="DAV:"/>',
        "<propfind",
        "not xml at all",
      ]) {
        expect(() => parsePropfind(_b(bad)), throwsFormatException, reason: bad);
      }
    });

    test("DTDs and entities are refused before parsing", () {
      expect(
        () => parsePropfind(_b('<?xml version="1.0"?><!DOCTYPE p [<!ENTITY x "y">]><propfind xmlns="DAV:"><allprop/></propfind>')),
        throwsFormatException,
      );
    });
  });

  group("parseLockInfo", () {
    test("reads scope and owner", () {
      final LockRequest request = parseLockInfo(
        _b(
          '<D:lockinfo xmlns:D="DAV:"><D:lockscope><D:shared/></D:lockscope>'
          "<D:locktype><D:write/></D:locktype><D:owner><D:href>bob</D:href></D:owner></D:lockinfo>",
        ),
      );
      expect(request.scope, DavLockScope.shared);
      expect(request.owner, "bob");
    });

    test("needs a scope and a write type", () {
      expect(() => parseLockInfo(_b('<D:lockinfo xmlns:D="DAV:"><D:locktype><D:write/></D:locktype></D:lockinfo>')), throwsFormatException);
      expect(
        () => parseLockInfo(_b('<D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope></D:lockinfo>')),
        throwsFormatException,
      );
      expect(() => parseLockInfo(_b("<x/>")), throwsFormatException);
    });

    test("a very long owner is cut", () {
      final LockRequest request = parseLockInfo(
        _b(
          '<D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype>'
          "<D:owner>${"x" * 1000}</D:owner></D:lockinfo>",
        ),
      );
      expect(request.owner.length, 256);
    });
  });

  group("parsePropertyUpdate", () {
    test("collects set and remove properties", () {
      final List<DavProp> props = parsePropertyUpdate(
        _b(
          '<D:propertyupdate xmlns:D="DAV:" xmlns:Z="urn:z"><D:set><D:prop><Z:a>1</Z:a></D:prop></D:set>'
          "<D:remove><D:prop><Z:b/></D:prop></D:remove></D:propertyupdate>",
        ),
      );
      expect(props, <DavProp>[const DavProp("urn:z", "a"), const DavProp("urn:z", "b")]);
    });
  });

  group("MultiStatus", () {
    test("builds escaped, well-formed XML", () {
      final MultiStatus out = MultiStatus()
        ..response("/dav/a&b/", <PropStat>[
          const PropStat(200, <String>["<D:displayname>a&amp;b</D:displayname>"]),
          const PropStat(404, <String>["<D:foo/>"]),
        ]);
      final String xml = utf8.decode(out.toBytes());

      expect(xml, contains("<D:href>/dav/a&amp;b/</D:href>"));
      expect(xml, contains("HTTP/1.1 200 OK"));
      expect(xml, contains("HTTP/1.1 404 Not Found"));
      expect(xml, startsWith('<?xml version="1.0" encoding="utf-8"?>'));
      expect(xml, endsWith("</D:multistatus>"));
    });

    test("emptyPropXml refuses names that aren't safe XML names", () {
      expect(emptyPropXml(const DavProp.dav("ok-name")), "<D:ok-name/>");
      expect(emptyPropXml(const DavProp("urn:x", "a")), '<X:a xmlns:X="urn:x"/>');
      expect(emptyPropXml(const DavProp.dav("bad name")), isNull);
      expect(emptyPropXml(const DavProp.dav("<script>")), isNull);
      expect(emptyPropXml(const DavProp('urn:"><x', "a")), contains("&quot;"));
    });
  });

  group("DavLockManager", () {
    late FakeClock clock;
    late DavLockManager locks;

    DavLock? lock(String key, {String account = "a1", bool deep = true, DavLockScope scope = DavLockScope.exclusive, Duration? timeout}) =>
        locks.create(accountId: account, resourceKey: key, depthInfinity: deep, scope: scope, owner: "me", requested: timeout);

    setUp(() {
      clock = FakeClock();
      locks = DavLockManager(clock: clock);
    });

    test("tokens look like opaquelocktoken:<uuid> and are unique", () {
      final DavLock a = lock("r1/a")!;
      final DavLock b = lock("r1/b")!;
      expect(a.token, startsWith("opaquelocktoken:"));
      expect(a.token, isNot(b.token));
    });

    test("an exclusive lock blocks any other lock on the same or covered resource", () {
      lock("r1/dir");
      expect(lock("r1/dir"), isNull);
      expect(lock("r1/dir/file"), isNull, reason: "covered by the depth-infinity lock");
      expect(lock("r1/other"), isNotNull);
      expect(lock("r2/dir"), isNotNull, reason: "a different root");
    });

    test("a lock above an existing lock conflicts when it is deep, not when it is shallow", () {
      lock("r1/dir/file");
      expect(lock("r1/dir", deep: true), isNull);
      expect(lock("r1/dir", deep: false), isNotNull);
    });

    test("shared locks coexist; an exclusive one can't join them", () {
      expect(lock("r1/f", scope: DavLockScope.shared), isNotNull);
      expect(lock("r1/f", account: "a2", scope: DavLockScope.shared), isNotNull);
      expect(lock("r1/f", scope: DavLockScope.exclusive), isNull);
    });

    test("names that merely share a prefix are different resources", () {
      lock("r1/doc");
      expect(lock("r1/docs"), isNotNull);
      expect(lock("r10/doc"), isNotNull);
    });

    test("mayModify: unlocked is free; locked needs the owner AND the token", () {
      final DavLock held = lock("r1/dir")!;

      expect(locks.mayModify("a1", "r1/elsewhere", const <String>{}), isTrue);
      expect(locks.mayModify("a1", "r1/dir/file", const <String>{}), isFalse);
      expect(locks.mayModify("a1", "r1/dir/file", <String>{held.token}), isTrue);
      expect(locks.mayModify("a2", "r1/dir/file", <String>{held.token}), isFalse, reason: "someone else's token");
      expect(locks.mayModify("a1", "r1/dir/file", const <String>{"opaquelocktoken:other"}), isFalse);
    });

    test("includeDescendants: touching a folder is blocked by locks inside it", () {
      final DavLock inner = lock("r1/dir/file")!;
      expect(locks.mayModify("a1", "r1/dir", const <String>{}), isTrue);
      expect(locks.mayModify("a1", "r1/dir", const <String>{}, includeDescendants: true), isFalse);
      expect(locks.mayModify("a1", "r1/dir", <String>{inner.token}, includeDescendants: true), isTrue);
    });

    test("locks expire, and the timeout is capped", () {
      final DavLock quick = lock("r1/a", timeout: const Duration(seconds: 30))!;
      final DavLock long = lock("r1/b", timeout: const Duration(days: 3))!;
      expect(long.timeout, const Duration(hours: 1));

      clock.advance(const Duration(seconds: 31));
      expect(locks.locksOn("r1/a"), isEmpty);
      expect(locks.mayModify("a1", "r1/a", const <String>{}), isTrue);
      expect(quick.token, isNotEmpty);
      expect(locks.locksOn("r1/b"), hasLength(1));
    });

    test("refresh extends; only the owner can refresh or unlock", () {
      final DavLock held = lock("r1/a", timeout: const Duration(seconds: 30))!;
      clock.advance(const Duration(seconds: 20));

      expect(locks.refresh(held.token, "a2"), isNull);
      expect(locks.refresh(held.token, "a1", requested: const Duration(seconds: 30)), isNotNull);
      clock.advance(const Duration(seconds: 20));
      expect(locks.locksOn("r1/a"), hasLength(1));

      expect(locks.unlock(held.token, "a2"), isFalse);
      expect(locks.unlock(held.token, "a1"), isTrue);
      expect(locks.unlock(held.token, "a1"), isFalse);
      expect(locks.locksOn("r1/a"), isEmpty);
    });

    test("the number of locks is bounded", () {
      locks = DavLockManager(clock: clock, maxLocks: 2);
      expect(lock("r1/a"), isNotNull);
      expect(lock("r1/b"), isNotNull);
      expect(lock("r1/c"), isNull);
      expect(locks.length, 2);
    });

    test("tokensIn finds every token in an If header", () {
      expect(
        DavLockManager.tokensIn("(<opaquelocktoken:abc-123> [\"etag\"]) <http://x/y> (Not <opaquelocktoken:def-456>)"),
        <String>{"opaquelocktoken:abc-123", "opaquelocktoken:def-456"},
      );
      expect(DavLockManager.tokensIn(null), isEmpty);
      expect(DavLockManager.tokensIn("nothing"), isEmpty);
    });

    test("parseTimeout reads Second-N and Infinite", () {
      expect(DavLockManager.parseTimeout("Second-600"), const Duration(seconds: 600));
      expect(DavLockManager.parseTimeout("Infinite, Second-4100000000"), const Duration(days: 1));
      expect(DavLockManager.parseTimeout("second-5"), const Duration(seconds: 5));
      expect(DavLockManager.parseTimeout("nonsense"), isNull);
      expect(DavLockManager.parseTimeout(null), isNull);
    });
  });
}
