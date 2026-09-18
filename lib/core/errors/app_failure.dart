/// Typed failure hierarchy per `03_System_Architecture_MVVM.md` ("Error
/// architecture"). Views never parse exception strings or platform
/// exceptions directly (doc §16/§20/kickoff §71) — every layer below the
/// ViewModel maps its failures into one of these before they cross the
/// boundary, and every UI-facing message is written for a person, with the
/// raw detail available only behind "Technical details >" (kickoff §71).
sealed class AppFailure implements Exception {
  const AppFailure({required this.message, this.debugDetail});

  /// Short, human-readable message safe to show directly in the UI. Never a
  /// raw exception's `toString()` — see kickoff §71 ("We can't write to this
  /// storage location", not "PlatformException(IOException EPERM)").
  final String message;

  /// Optional technical detail, shown only behind an explicit
  /// "Technical details" disclosure. Must never contain a secret
  /// (password, token, session cookie, Vault key — doc §12/§16/§57).
  final String? debugDetail;

  @override
  String toString() => "$runtimeType: $message";
}

// --- Storage failures ---

final class PermissionRevokedFailure extends AppFailure {
  const PermissionRevokedFailure({super.debugDetail})
    : super(
        message:
            "VaultBox no longer has permission to reach this storage location. "
            "Reconnect it to continue.",
      );
}

final class StorageDisconnectedFailure extends AppFailure {
  const StorageDisconnectedFailure({required this.rootId, super.debugDetail})
    : super(
        message:
            "This storage location isn't reachable right now. "
            "Reconnect the SD card / drive, or choose another folder.",
      );

  final String rootId;
}

final class NotEnoughSpaceFailure extends AppFailure {
  const NotEnoughSpaceFailure({super.debugDetail})
    : super(message: "There isn't enough free space to finish this.");
}

final class PathConflictFailure extends AppFailure {
  const PathConflictFailure({required this.path, super.debugDetail})
    : super(message: "Something already exists at that location.");

  final String path;
}

/// An operation that is well-formed but must never run — e.g. copying a folder
/// into itself, or replacing a folder with something that lives inside it.
/// Raised by [FileRepository] as a last line of defence (the UI also
/// pre-validates), so a future protocol handler can't reach the destructive
/// paths by skipping the UI's checks.
final class InvalidOperationFailure extends AppFailure {
  const InvalidOperationFailure({required super.message, super.debugDetail});
}

/// The person's input was rejected (weak password, bad username…). [message]
/// is written to be shown to them directly.
final class ValidationFailure extends AppFailure {
  const ValidationFailure({required super.message, super.debugDetail});
}

final class PathTraversalRejectedFailure extends AppFailure {
  const PathTraversalRejectedFailure({super.debugDetail})
    : super(
        message: "That location isn't allowed.",
        // Deliberately generic user-facing message — doc §12/§42 treats path
        // traversal as a security boundary, not a normal user error to
        // explain in detail.
      );
}

// --- Server failures (Phase 2+, defined now so the failure hierarchy is
// stable before the server runtime lands) ---

final class PortInUseFailure extends AppFailure {
  const PortInUseFailure({required this.port, super.debugDetail})
    : super(message: "Port $port is already in use.");

  final int port;
}

final class BindFailedFailure extends AppFailure {
  const BindFailedFailure({super.debugDetail})
    : super(message: "The server couldn't bind to the network.");
}

final class ProtocolStartFailedFailure extends AppFailure {
  const ProtocolStartFailedFailure({required this.protocol, super.debugDetail})
    : super(message: "$protocol couldn't start. Other services stay live.");

  final String protocol;
}

// --- Auth / network / crypto / database ---

final class AuthFailure extends AppFailure {
  const AuthFailure({required super.message, super.debugDetail});
}

final class NetworkFailure extends AppFailure {
  const NetworkFailure({super.debugDetail})
    : super(message: "A network problem interrupted this.");
}

final class CryptoFailure extends AppFailure {
  const CryptoFailure({required super.message, super.debugDetail});
}

final class DatabaseFailure extends AppFailure {
  const DatabaseFailure({super.debugDetail})
    : super(message: "A local data error occurred. Nothing was lost.");
}

/// Fallback for a genuinely unexpected programmer error surfaced at a
/// boundary (doc §20: "unexpected programmer errors may throw and be
/// captured at boundaries"). Should be rare in practice — most code paths
/// should produce a specific [AppFailure] subtype instead.
final class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure({super.debugDetail})
    : super(message: "Something went wrong. Please try again.");
}
