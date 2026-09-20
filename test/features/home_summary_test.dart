import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/activity.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/features/home/home_summary.dart";

void main() {
  final DateTime now = DateTime.utc(2026, 9, 20, 12);

  ActivityEvent started(Duration ago, {String id = "s"}) =>
      ActivityEvent(id: id, at: now.subtract(ago), kind: ActivityKind.serverStarted, message: "The server started.");

  const ServerState running = ServerState(run: ServerRunState.running, endpoint: "https://192.168.1.5:8443/");

  group("serverUptime", () {
    test("is the time since the most recent start", () {
      final Duration? uptime = serverUptime(
        running,
        <ActivityEvent>[started(const Duration(hours: 2), id: "new"), started(const Duration(days: 3), id: "old")],
        now,
      );

      expect(uptime, const Duration(hours: 2));
    });

    test("is unknown when the server isn't running, or its start isn't in the history", () {
      expect(serverUptime(const ServerState.stopped(), <ActivityEvent>[started(const Duration(hours: 1))], now), isNull);
      expect(serverUptime(running, const <ActivityEvent>[], now), isNull);
      expect(
        serverUptime(
          running,
          <ActivityEvent>[
            ActivityEvent(id: "x", at: now, kind: ActivityKind.signedIn, message: "someone signed in"),
          ],
          now,
        ),
        isNull,
      );
    });

    test("never goes negative when clocks disagree", () {
      expect(serverUptime(running, <ActivityEvent>[started(const Duration(seconds: -30))], now), Duration.zero);
    });
  });

  test("formatUptime is hours, minutes and seconds", () {
    expect(formatUptime(Duration.zero), "00:00:00");
    expect(formatUptime(const Duration(hours: 4, minutes: 28, seconds: 15)), "04:28:15");
    expect(formatUptime(const Duration(hours: 130, minutes: 5, seconds: 9)), "130:05:09");
  });

  group("addresses", () {
    test("the primary address is the encrypted one, without its trailing slash", () {
      const ServerState both = ServerState(
        run: ServerRunState.running,
        endpoints: <String>["http://192.168.1.5:8080/", "https://192.168.1.5:8443/"],
      );

      expect(primaryAddress(both), "https://192.168.1.5:8443");
      expect(lanHostPort(both), "192.168.1.5:8443");
    });

    test("nothing while the server isn't running", () {
      expect(primaryAddress(const ServerState.stopped()), isNull);
      expect(lanHostPort(const ServerState.stopped()), isNull);
    });

    test("an address that only this phone can reach has no LAN address", () {
      const ServerState local = ServerState(run: ServerRunState.running, endpoint: "https://127.0.0.1:8443/");

      expect(primaryAddress(local), "https://127.0.0.1:8443");
      expect(lanHostPort(local), isNull);
      expect(
        lanHostPort(const ServerState(run: ServerRunState.running, endpoint: "http://localhost:8080/")),
        isNull,
      );
    });
  });

  group("protocolStatuses", () {
    test("HTTPS and WebDAV by default, all off while stopped", () {
      final List<ProtocolStatus> list = protocolStatuses(const ServerState.stopped(), const ServerConfig());

      expect(list.map((ProtocolStatus p) => p.label), <String>["HTTPS", "WebDAV"]);
      expect(list.map((ProtocolStatus p) => p.port), <String>["8443", "/dav"]);
      expect(list.every((ProtocolStatus p) => !p.active), isTrue);
    });

    test("listening while the server runs, and plain HTTP shows only when it is on", () {
      final List<ProtocolStatus> list = protocolStatuses(running, const ServerConfig(httpEnabled: true));

      expect(list.map((ProtocolStatus p) => p.label), <String>["HTTPS", "HTTP", "WebDAV"]);
      expect(list.map((ProtocolStatus p) => p.port), <String>["8443", "8080", "/dav"]);
      expect(list.every((ProtocolStatus p) => p.active), isTrue);
    });

    test("HTTPS is left out when it is switched off, and unknown settings use the defaults", () {
      expect(
        protocolStatuses(running, const ServerConfig(httpsEnabled: false, httpEnabled: true)).map((ProtocolStatus p) => p.label),
        <String>["HTTP", "WebDAV"],
      );
      expect(protocolStatuses(running, null).map((ProtocolStatus p) => p.label), <String>["HTTPS", "WebDAV"]);
    });
  });
}
