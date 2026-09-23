import "../entities/account.dart";
import "../entities/diagnostic.dart";
import "../entities/server_config.dart";
import "../entities/server_state.dart";
import "../entities/share.dart";
import "../entities/storage_root.dart";
import "../models/file_ref.dart";
import "../repositories/account_repository.dart";
import "../repositories/clock.dart";
import "../repositories/file_repository.dart";
import "../repositories/server_host.dart";
import "../repositories/share_repository.dart";
import "../repositories/storage_root_repository.dart";
import "../value_objects/storage_path.dart";

/// Looks at every part that has to work for VaultBox to be useful, and says in
/// plain words what it found. Each check runs on its own: one that can't be
/// carried out is reported as a problem and never stops the others.
final class RunDiagnostics {
  const RunDiagnostics({
    required StorageRootRepository roots,
    required FileRepository files,
    required AccountRepository accounts,
    required ShareRepository shares,
    required ServerHost server,
    required Clock clock,
  }) : _roots = roots,
       _files = files,
       _accounts = accounts,
       _shares = shares,
       _server = server,
       _clock = clock;

  final StorageRootRepository _roots;
  final FileRepository _files;
  final AccountRepository _accounts;
  final ShareRepository _shares;
  final ServerHost _server;
  final Clock _clock;

  Future<List<DiagnosticCheck>> call() async {
    return <DiagnosticCheck>[
      ...await _guard("Storage", _storage),
      ...await _guard("Accounts", _accountsCheck),
      ...await _guard("Server", _serverCheck),
      ...await _guard("Connections", _connections),
      ...await _guard("Encryption certificate", _certificate),
      ...await _guard("Links", _links),
    ];
  }

  Future<List<DiagnosticCheck>> _guard(String title, Future<List<DiagnosticCheck>> Function() check) async {
    try {
      return await check();
    } on Object {
      return <DiagnosticCheck>[
        DiagnosticCheck(
          title: title,
          status: DiagnosticStatus.problem,
          detail: "This check couldn't be carried out.",
          hint: "Close and reopen VaultBox, then run the checks again.",
        ),
      ];
    }
  }

  // ---------------------------------------------------------------- storage

  Future<List<DiagnosticCheck>> _storage() async {
    final List<StorageRoot> roots = (await _roots.listRoots()).where((StorageRoot r) => r.isEnabled).toList();
    if (roots.isEmpty) {
      return const <DiagnosticCheck>[
        DiagnosticCheck(
          title: "Storage location",
          status: DiagnosticStatus.warning,
          detail: "No storage location is set up, so there is nothing to share.",
          hint: "Add one in the Files tab.",
        ),
      ];
    }

    final List<DiagnosticCheck> results = <DiagnosticCheck>[];
    for (final StorageRoot root in roots) {
      if (!root.isAvailable) {
        results.add(
          DiagnosticCheck(
            title: "Storage location",
            subject: root.displayName,
            status: DiagnosticStatus.problem,
            detail: "Can't be reached right now.",
            hint: "If it is an SD card or a USB drive, plug it back in. Otherwise add the folder again.",
          ),
        );
        continue;
      }
      try {
        await _files.list(FileRef(root: root, path: StoragePath.root(root.id)), pageSize: 1).take(1).toList();
        results.add(
          DiagnosticCheck(
            title: "Storage location",
            subject: root.displayName,
            status: DiagnosticStatus.ok,
            detail: root.capabilities.canWrite ? "Readable and writable." : "Readable, but read-only.",
          ),
        );
      } on Object {
        results.add(
          DiagnosticCheck(
            title: "Storage location",
            subject: root.displayName,
            status: DiagnosticStatus.problem,
            detail: "Reachable, but its files can't be listed.",
            hint: "VaultBox may have lost permission to the folder. Add it again.",
          ),
        );
      }
    }
    return results;
  }

  // --------------------------------------------------------------- accounts

  Future<List<DiagnosticCheck>> _accountsCheck() async {
    final List<Account> all = await _accounts.listAll();
    final int admins = all.where((Account a) => a.isAdmin && a.isEnabled).length;
    if (admins == 0) {
      return const <DiagnosticCheck>[
        DiagnosticCheck(
          title: "Accounts",
          status: DiagnosticStatus.problem,
          detail: "There is no admin account, so nobody can sign in.",
          hint: "Create one on the Home tab.",
        ),
      ];
    }
    final int members = all.where((Account a) => !a.isAdmin && a.isEnabled).length;
    return <DiagnosticCheck>[
      DiagnosticCheck(
        title: "Accounts",
        status: DiagnosticStatus.ok,
        detail: "$admins admin${admins == 1 ? "" : "s"} and $members member${members == 1 ? "" : "s"} can sign in.",
      ),
    ];
  }

  // ----------------------------------------------------------------- server

  Future<ServerState> _state() => _server.watch().first.timeout(const Duration(seconds: 3));

  Future<List<DiagnosticCheck>> _serverCheck() async {
    final ServerState state = await _state();
    switch (state.run) {
      case ServerRunState.running:
        final int count = state.endpoints.isNotEmpty ? state.endpoints.length : (state.endpoint == null ? 0 : 1);
        return <DiagnosticCheck>[
          DiagnosticCheck(
            title: "Server",
            status: DiagnosticStatus.ok,
            detail: "Running on $count address${count == 1 ? "" : "es"}.",
          ),
        ];
      case ServerRunState.starting:
        return const <DiagnosticCheck>[
          DiagnosticCheck(title: "Server", status: DiagnosticStatus.warning, detail: "Still starting."),
        ];
      case ServerRunState.failed:
        return <DiagnosticCheck>[
          DiagnosticCheck(
            title: "Server",
            status: DiagnosticStatus.problem,
            detail: state.detail == null ? "It couldn't start." : "It couldn't start: ${state.detail}",
            hint: "Another app may be using the port. Stop the server, change the port or try again.",
          ),
        ];
      case ServerRunState.stopped:
        return const <DiagnosticCheck>[
          DiagnosticCheck(
            title: "Server",
            status: DiagnosticStatus.ok,
            detail: "Off. Nothing is reachable until you start it on the Home tab.",
          ),
        ];
    }
  }

  Future<List<DiagnosticCheck>> _connections() async {
    final ServerConfig config = await _server.config();
    if (!config.httpsEnabled && !config.httpEnabled) {
      return const <DiagnosticCheck>[
        DiagnosticCheck(
          title: "Connections",
          status: DiagnosticStatus.problem,
          detail: "Neither HTTPS nor HTTP is switched on, so the server has nothing to listen on.",
          hint: "Switch HTTPS on in the Home tab.",
        ),
      ];
    }
    if (config.allowNetworkAccess && config.httpEnabled) {
      return <DiagnosticCheck>[
        DiagnosticCheck(
          title: "Connections",
          status: DiagnosticStatus.warning,
          detail: config.httpsEnabled
              ? "Plain HTTP is on next to HTTPS. Passwords sent over HTTP can be read on the network."
              : "Only plain HTTP is on. Passwords sent over it can be read on the network.",
          hint: "Switch HTTP off unless you need it, and use HTTPS.",
        ),
      ];
    }
    return <DiagnosticCheck>[
      DiagnosticCheck(
        title: "Connections",
        status: DiagnosticStatus.ok,
        detail: config.allowNetworkAccess
            ? "Devices on your network can connect over HTTPS."
            : "Only this phone can connect.",
      ),
    ];
  }

  Future<List<DiagnosticCheck>> _certificate() async {
    final ServerConfig config = await _server.config();
    if (!config.httpsEnabled) {
      return const <DiagnosticCheck>[
        DiagnosticCheck(title: "Encryption certificate", status: DiagnosticStatus.ok, detail: "HTTPS is off."),
      ];
    }
    final String fingerprint = await _server.tlsFingerprint();
    if (fingerprint.trim().isEmpty) {
      return const <DiagnosticCheck>[
        DiagnosticCheck(
          title: "Encryption certificate",
          status: DiagnosticStatus.problem,
          detail: "There is no certificate for HTTPS.",
          hint: "Stop and start the server to create one.",
        ),
      ];
    }
    return const <DiagnosticCheck>[
      DiagnosticCheck(
        title: "Encryption certificate",
        status: DiagnosticStatus.ok,
        detail: "Present. Browsers warn about it because it is self-signed; compare its fingerprint on the Home tab.",
      ),
    ];
  }

  // ------------------------------------------------------------------ links

  Future<List<DiagnosticCheck>> _links() async {
    final List<Share> all = await _shares.list();
    final DateTime now = _clock.now();
    final int active = all.where((Share s) => s.isActive(now)).length;
    final int finished = all.length - active;
    return <DiagnosticCheck>[
      DiagnosticCheck(
        title: "Links",
        status: DiagnosticStatus.ok,
        detail: all.isEmpty
            ? "No links have been made."
            : "$active active link${active == 1 ? "" : "s"}"
                  "${finished == 0 ? "" : " and $finished expired or used up"}.",
      ),
    ];
  }
}
