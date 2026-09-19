import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/security/download_tickets.dart";

import "../helpers/fake_clock.dart";

void main() {
  late FakeClock clock;
  late DownloadTicketService tickets;

  String issue({String session = "s1", String path = "/a.txt"}) =>
      tickets.issue(accountId: "a1", sessionHash: session, rootId: "r1", path: path);

  setUp(() {
    clock = FakeClock();
    tickets = DownloadTicketService(clock: clock);
  });

  test("a ticket resolves to exactly what it was issued for", () {
    final String token = issue(path: "/docs/a.txt");
    final DownloadTicket? ticket = tickets.resolve(token);

    expect(ticket?.accountId, "a1");
    expect(ticket?.rootId, "r1");
    expect(ticket?.path, "/docs/a.txt");
    expect(ticket?.sessionHash, "s1");
  });

  test("tickets are long, random and different every time", () {
    final Set<String> seen = <String>{for (int i = 0; i < 50; i++) issue()};
    expect(seen, hasLength(50));
    expect(seen.every((String t) => t.length >= 40), isTrue);
  });

  test("unknown, empty and oversized tokens resolve to nothing", () {
    issue();
    expect(tickets.resolve("nope"), isNull);
    expect(tickets.resolve(""), isNull);
    expect(tickets.resolve("x" * 200), isNull);
  });

  test("a ticket expires after its lifetime", () {
    final String token = issue();

    clock.advance(const Duration(minutes: 14, seconds: 59));
    expect(tickets.resolve(token), isNotNull);

    clock.advance(const Duration(seconds: 2));
    expect(tickets.resolve(token), isNull);
    expect(tickets.length, 0, reason: "an expired ticket is dropped when seen");
  });

  test("a ticket can be used more than once until it expires (ranges, seeking)", () {
    final String token = issue();
    expect(tickets.resolve(token), isNotNull);
    expect(tickets.resolve(token), isNotNull);
  });

  test("revoking a session kills only that session's tickets", () {
    final String mine = issue(session: "s1");
    final String other = issue(session: "s2");

    tickets.revokeSession("s1");

    expect(tickets.resolve(mine), isNull);
    expect(tickets.resolve(other), isNotNull);
  });

  test("purgeExpired removes only the expired ones", () {
    final String old = issue();
    clock.advance(const Duration(minutes: 10));
    final String fresh = issue();
    clock.advance(const Duration(minutes: 6));

    expect(tickets.purgeExpired(), 1);
    expect(tickets.resolve(old), isNull);
    expect(tickets.resolve(fresh), isNotNull);
  });

  test("the store is bounded: the oldest ticket is dropped first", () {
    tickets = DownloadTicketService(clock: clock, maxTickets: 3);
    final String first = issue(path: "/1");
    issue(path: "/2");
    issue(path: "/3");
    final String last = issue(path: "/4");

    expect(tickets.length, 3);
    expect(tickets.resolve(first), isNull);
    expect(tickets.resolve(last), isNotNull);
  });
}
