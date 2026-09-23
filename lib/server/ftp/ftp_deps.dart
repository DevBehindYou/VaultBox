import "../../domain/repositories/file_repository.dart";
import "../../domain/usecases/delete_items_to_recycle_bin.dart";
import "../../domain/usecases/move_items.dart";
import "../activity/activity_log.dart";
import "../files/storage_gate.dart";
import "../webdav/dav_auth.dart";

/// What an FTP session needs from the rest of the server. Everything that
/// touches files goes through the same gate and transfer code the web API and
/// WebDAV use, so a rule can't hold on one door and be missing on another.
final class FtpDeps {
  const FtpDeps({
    required this.gate,
    required this.files,
    required this.delete,
    required this.move,
    required this.auth,
    required this.activity,
  });

  final StorageGate gate;
  final FileRepository files;
  final DeleteItemsToRecycleBin delete;
  final MoveItems move;

  /// Checks a username and password. FTP logs in once per connection, and some
  /// clients open several at once, so this reuses WebDAV's verified-login cache
  /// and its throttling rather than running a slow password hash each time.
  final DavAuthenticator auth;
  final ActivityLog activity;
}

/// Time and size limits, so a stuck or hostile client can't hold resources.
final class FtpLimits {
  const FtpLimits({
    this.idleTimeout = const Duration(minutes: 5),
    this.dataConnectTimeout = const Duration(seconds: 30),
    this.dataIdleTimeout = const Duration(seconds: 60),
    this.tlsHandshakeTimeout = const Duration(seconds: 15),
    this.failedLoginDelay = const Duration(seconds: 1),
    this.maxFailedLogins = 3,
    this.maxConnections = 8,
    this.maxConnectionsPerAddress = 4,
    this.maxCommandBytes = 4096,
    this.maxListedEntries = 50000,
  });

  /// A control connection with no command for this long is closed.
  final Duration idleTimeout;

  /// How long to wait for the client to open the data connection.
  final Duration dataConnectTimeout;

  /// A transfer that moves no bytes for this long is abandoned.
  final Duration dataIdleTimeout;

  /// How long a TLS handshake may take.
  final Duration tlsHandshakeTimeout;

  /// Pause after a wrong password, to slow guessing on one connection.
  final Duration failedLoginDelay;

  /// Wrong passwords on one connection before it is closed.
  final int maxFailedLogins;

  final int maxConnections;
  final int maxConnectionsPerAddress;

  /// The longest command line accepted.
  final int maxCommandBytes;

  /// The most entries one listing may have.
  final int maxListedEntries;
}
