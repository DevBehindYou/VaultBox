import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/activity.dart";
import "package:vaultbox/domain/entities/diagnostic.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/domain/usecases/build_support_bundle.dart";

void main() {
  final DateTime now = DateTime.utc(2026, 9, 20, 12);

  String bundle({
    ServerState server = const ServerState.stopped(),
    ServerConfig config = const ServerConfig(),
    List<DiagnosticCheck> checks = const <DiagnosticCheck>[],
    List<ActivityEvent> events = const <ActivityEvent>[],
    List<TransferRecord> transfers = const <TransferRecord>[],
    int maxEvents = 50,
  }) => buildSupportBundle(
    now: now,
    appVersion: "1.2.3",
    server: server,
    config: config,
    checks: checks,
    events: events,
    transfers: transfers,
    maxEvents: maxEvents,
  );

  ActivityEvent event(int minute, {String message = "something", String? actor, String? address}) => ActivityEvent(
    id: "e$minute",
    at: now.subtract(Duration(minutes: minute)),
    kind: ActivityKind.signInRefused,
    severity: ActivitySeverity.warning,
    message: message,
    actor: actor,
    address: address,
  );

  TransferRecord transfer(String id, TransferState state) => TransferRecord(
    id: id,
    direction: TransferDirection.download,
    via: AccessVia.web,
    actor: "bob",
    name: "$id-holiday.jpg",
    startedAt: now,
    updatedAt: now,
    state: state,
  );

  test("says what made it, when, and the settings that matter", () {
    final String text = bundle(
      server: const ServerState(
        run: ServerRunState.running,
        endpoint: "https://192.168.1.5:8443/",
        endpoints: <String>["https://192.168.1.5:8443/"],
      ),
      config: const ServerConfig(allowNetworkAccess: true, httpEnabled: true),
    );

    expect(text, startsWith("VaultBox support bundle"));
    expect(text, contains("Made: 2026-09-20T12:00:00.000Z"));
    expect(text, contains("App version: 1.2.3"));
    expect(text, contains("State: running"));
    expect(text, contains("Addresses: 1"));
    expect(text, contains("Network access: on"));
    expect(text, contains("HTTPS: on (port 8443)"));
    expect(text, contains("HTTP: on (port 8080)"));
  });

  test("lists every check with its outcome", () {
    final String text = bundle(
      checks: const <DiagnosticCheck>[
        DiagnosticCheck(title: "Accounts", status: DiagnosticStatus.ok, detail: "1 admin can sign in."),
        DiagnosticCheck(title: "Server", status: DiagnosticStatus.problem, detail: "It couldn't start."),
        DiagnosticCheck(title: "Connections", status: DiagnosticStatus.warning, detail: "Plain HTTP is on."),
      ],
    );

    expect(text, contains("[OK] Accounts: 1 admin can sign in."));
    expect(text, contains("[PROBLEM] Server: It couldn't start."));
    expect(text, contains("[WARNING] Connections: Plain HTTP is on."));
  });

  test("names no person, address, file, storage location or link", () {
    final String text = bundle(
      checks: const <DiagnosticCheck>[
        DiagnosticCheck(
          title: "Storage location",
          subject: "Aunt Mabel's tax scans",
          status: DiagnosticStatus.ok,
          detail: "Readable and writable.",
        ),
      ],
      events: <ActivityEvent>[
        event(1, message: "bob signed in from 192.168.1.77.", actor: "bob", address: "192.168.1.77"),
      ],
      transfers: <TransferRecord>[transfer("t1", TransferState.completed)],
    );

    expect(text, isNot(contains("bob")));
    expect(text, isNot(contains("192.168.1.77")));
    expect(text, isNot(contains("holiday.jpg")));
    expect(text, isNot(contains("Mabel")));
    expect(text, isNot(contains("signed in")), reason: "event wording is left out");
  });

  test("events appear by kind and time only, newest first as given, capped", () {
    final List<ActivityEvent> many = <ActivityEvent>[for (int i = 0; i < 10; i++) event(i)];

    final String text = bundle(events: many, maxEvents: 3);

    expect("signInRefused".allMatches(text), hasLength(3));
    expect(text, contains("2026-09-20T12:00:00.000Z  warning  signInRefused"));
    expect(text, contains("2026-09-20T11:58:00.000Z  warning  signInRefused"));
    expect(text, isNot(contains("2026-09-20T11:57:00.000Z")));
  });

  test("counts transfers by how they ended", () {
    final String text = bundle(
      transfers: <TransferRecord>[
        transfer("a", TransferState.completed),
        transfer("b", TransferState.completed),
        transfer("c", TransferState.failed),
        transfer("d", TransferState.interrupted),
        transfer("e", TransferState.running),
      ],
    );

    expect(text, contains("Transfers (most recent 5)"));
    expect(text, contains("Completed: 2"));
    expect(text, contains("Failed: 1"));
    expect(text, contains("Interrupted: 1"));
    expect(text, contains("Running: 1"));
  });

  test("a failed server's own reason is kept: that is what someone helping needs", () {
    final String text = bundle(server: const ServerState(run: ServerRunState.failed, detail: "Address already in use"));

    expect(text, contains("Detail: Address already in use"));
  });
}
