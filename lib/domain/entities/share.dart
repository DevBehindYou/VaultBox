enum ShareKind {
  /// Anyone with the link can download the shared file or folder's contents.
  download,

  /// Anyone with the link can send files INTO the shared folder — and see nothing in it.
  upload,
}

/// A link someone made for people who have no account.
///
/// The link's secret token is never stored: only [tokenHash] (its SHA-256) is,
/// so a copy of the database can't be turned into working links. That is also
/// why the token can only be shown once, when the link is made.
final class Share {
  const Share({
    required this.id,
    required this.kind,
    required this.rootId,
    required this.path,
    required this.isDirectory,
    required this.createdBy,
    required this.createdAt,
    required this.tokenHash,
    this.label,
    this.expiresAt,
    this.passwordHash,
    this.maxUses,
    this.useCount = 0,
    this.maxFileBytes,
  });

  final String id;
  final ShareKind kind;
  final String rootId;

  /// Normalized path of the shared file or folder (`/Photos/2026`).
  final String path;
  final bool isDirectory;

  /// The account that made it. Its rights are re-checked whenever the link is used.
  final String createdBy;
  final DateTime createdAt;
  final String tokenHash;

  /// A name the owner gave it, shown in their list.
  final String? label;
  final DateTime? expiresAt;

  /// Argon2id hash of the link's password, if it has one.
  final String? passwordHash;

  /// Most downloads (or uploaded files) allowed; `null` = no limit.
  final int? maxUses;
  final int useCount;

  /// Upload links only: the biggest single file accepted.
  final int? maxFileBytes;

  bool get hasPassword => passwordHash != null;

  bool isExpired(DateTime now) => expiresAt != null && !now.isBefore(expiresAt!);

  bool get isUsedUp => maxUses != null && useCount >= maxUses!;

  bool isActive(DateTime now) => !isExpired(now) && !isUsedUp;

  Share copyWith({int? useCount}) => Share(
    id: id,
    kind: kind,
    rootId: rootId,
    path: path,
    isDirectory: isDirectory,
    createdBy: createdBy,
    createdAt: createdAt,
    tokenHash: tokenHash,
    label: label,
    expiresAt: expiresAt,
    passwordHash: passwordHash,
    maxUses: maxUses,
    useCount: useCount ?? this.useCount,
    maxFileBytes: maxFileBytes,
  );
}
