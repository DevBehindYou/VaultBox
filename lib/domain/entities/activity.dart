/// How much attention an [ActivityEvent] deserves.
enum ActivitySeverity {
  info,

  /// Worth a look: a refused sign-in, an unencrypted connection.
  warning,

  /// Something broke.
  problem,
}

enum ActivityKind {
  serverStarted,
  serverStopped,
  signedIn,
  signInRefused,
  signedOut,

  /// Someone with a link (no account) opened, downloaded or sent something.
  linkUsed,
  problem,

  /// Anything a newer version wrote that this one doesn't know.
  other,
}

/// One thing that happened, in a sentence a person can read. The sentence is
/// stored as written (it never contains a password, a token or a file's bytes).
final class ActivityEvent {
  const ActivityEvent({
    required this.id,
    required this.at,
    required this.kind,
    required this.message,
    this.severity = ActivitySeverity.info,
    this.actor,
    this.address,
  });

  final String id;
  final DateTime at;
  final ActivityKind kind;
  final String message;
  final ActivitySeverity severity;

  /// The username involved, if any.
  final String? actor;

  /// The network address the request came from, if any.
  final String? address;
}

/// Which door someone came through.
enum AccessVia {
  /// The browser page and its API.
  web,

  /// A WebDAV app or a mounted drive.
  webdav,

  /// A share or upload-request link (no account).
  link,

  /// An FTP or FTPS client.
  ftp,
}

enum TransferDirection {
  /// Someone took a file from the phone.
  download,

  /// Someone sent a file to the phone.
  upload,
}

enum TransferState {
  running,
  completed,

  /// Stopped by an error on the phone's side (storage, disk full, size limit…).
  failed,

  /// The other side went away, or the server stopped, before it finished.
  interrupted,
}

/// One file moving in or out.
final class TransferRecord {
  const TransferRecord({
    required this.id,
    required this.direction,
    required this.via,
    required this.actor,
    required this.name,
    required this.startedAt,
    required this.updatedAt,
    this.finishedAt,
    this.bytes = 0,
    this.totalBytes,
    this.state = TransferState.running,
  });

  final String id;
  final TransferDirection direction;
  final AccessVia via;

  /// A username, or a description such as "Link" for people without an account.
  final String actor;

  /// The file's name (never its full path).
  final String name;
  final DateTime startedAt;

  /// The last time [bytes] moved.
  final DateTime updatedAt;
  final DateTime? finishedAt;
  final int bytes;

  /// The size it will reach, when known up front.
  final int? totalBytes;
  final TransferState state;

  bool get isRunning => state == TransferState.running;

  /// 0..1, or `null` when the total isn't known (or is zero).
  double? get fraction {
    final int? total = totalBytes;
    if (total == null || total <= 0) return null;
    final double value = bytes / total;
    return value > 1 ? 1 : value;
  }

  TransferRecord copyWith({
    int? bytes,
    DateTime? updatedAt,
    DateTime? finishedAt,
    TransferState? state,
  }) => TransferRecord(
    id: id,
    direction: direction,
    via: via,
    actor: actor,
    name: name,
    startedAt: startedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    bytes: bytes ?? this.bytes,
    totalBytes: totalBytes,
    state: state ?? this.state,
  );
}

/// Someone (or something) that has been talking to the server. There is one row
/// per person and address, so a phone and a laptop signed in as the same person
/// are two clients.
final class ClientRecord {
  const ClientRecord({
    required this.actor,
    required this.address,
    required this.via,
    required this.firstSeenAt,
    required this.lastSeenAt,
  });

  final String actor;
  final String address;
  final AccessVia via;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;

  String get key => "$actor|$address";
}
