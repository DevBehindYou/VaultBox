import "../../core/errors/app_failure.dart";
import "../entities/account.dart";
import "../entities/share.dart";
import "../entities/storage_root.dart";
import "../models/file_ref.dart";
import "../repositories/clock.dart";
import "../repositories/file_repository.dart";
import "../repositories/id_generator.dart";
import "../repositories/share_repository.dart";
import "../repositories/storage_root_repository.dart";
import "../security/authorizer.dart";
import "../security/password_hasher.dart";
import "../security/share_tokens.dart";
import "../value_objects/storage_entry.dart";
import "../value_objects/storage_path.dart";

/// A new link plus its secret [token]. The token is shown to the person ONCE;
/// only its hash is stored.
final class CreatedShare {
  const CreatedShare({required this.share, required this.token});

  final Share share;
  final String token;
}

/// Makes a download link (one file or folder) or an upload-request link (a
/// folder people can send files into, without seeing what is in it).
///
/// The maker must be allowed to do what the link does: `read` for a download
/// link, `write` for an upload link. All limits are checked before the (slow)
/// password hash is computed.
final class CreateShare {
  const CreateShare({
    required StorageRootRepository roots,
    required FileRepository files,
    required ShareRepository shares,
    required PasswordHasher hasher,
    required IdGenerator ids,
    required Clock clock,
    required Authorizer authorizer,
  }) : _roots = roots,
       _files = files,
       _shares = shares,
       _hasher = hasher,
       _ids = ids,
       _clock = clock,
       _authorizer = authorizer;

  final StorageRootRepository _roots;
  final FileRepository _files;
  final ShareRepository _shares;
  final PasswordHasher _hasher;
  final IdGenerator _ids;
  final Clock _clock;
  final Authorizer _authorizer;

  static const int minPasswordLength = 6;
  static const int maxPasswordLength = 128;
  static const Duration minLifetime = Duration(minutes: 1);
  static const Duration maxLifetime = Duration(days: 365);
  static const int maxUsesLimit = 100000;
  static const int maxFileBytesLimit = 1 << 40; // 1 TiB
  static const int maxLabelLength = 60;

  Future<CreatedShare> call({
    required Account creator,
    required ShareKind kind,
    required String rootId,
    required String path,
    Duration? lifetime,
    String? password,
    int? maxUses,
    int? maxFileBytes,
    String? label,
  }) async {
    if (lifetime != null && (lifetime < minLifetime || lifetime > maxLifetime)) {
      throw const ValidationFailure(message: "Choose an expiry between one minute and a year.");
    }
    if (maxUses != null && (maxUses < 1 || maxUses > maxUsesLimit)) {
      throw const ValidationFailure(message: "Choose a limit of at least 1.");
    }
    if (maxFileBytes != null && (kind != ShareKind.upload || maxFileBytes < 1 || maxFileBytes > maxFileBytesLimit)) {
      throw const ValidationFailure(message: "That file size limit isn't valid.");
    }
    final String? cleanLabel = label == null || label.trim().isEmpty ? null : label.trim();
    if (cleanLabel != null && cleanLabel.length > maxLabelLength) {
      throw const ValidationFailure(message: "That name is too long.");
    }
    if (password != null && (password.length < minPasswordLength || password.length > maxPasswordLength)) {
      throw const ValidationFailure(message: "Use a password of $minPasswordLength to $maxPasswordLength characters.");
    }

    final StorageRoot? root = await _roots.getRoot(rootId);
    if (root == null || !root.isEnabled || !root.isAvailable) {
      throw const ValidationFailure(message: "That storage isn't available right now.");
    }
    final StoragePath target;
    try {
      target = StoragePath.parseDecoded(root.id, path);
    } on AppFailure {
      throw const ValidationFailure(message: "That location isn't allowed.");
    }
    if (target.segments.isNotEmpty && target.segments.first.toLowerCase() == ".vaultbox") {
      throw const ValidationFailure(message: "VaultBox's own folder can't be shared.");
    }

    final Permission needed = kind == ShareKind.download ? Permission.read : Permission.write;
    if (!_authorizer.allows(creator, needed, root, target)) {
      throw const ValidationFailure(message: "You don't have access to share that.");
    }

    final bool isDirectory;
    if (target.isRoot) {
      isDirectory = true;
    } else {
      final StorageEntry? entry = await _files.statEntry(FileRef(root: root, path: target));
      if (entry == null) throw const ValidationFailure(message: "That item doesn't exist.");
      isDirectory = entry.isDirectory;
    }
    if (kind == ShareKind.upload) {
      if (!isDirectory) throw const ValidationFailure(message: "Uploads can only be received into a folder.");
      if (!root.capabilities.canWrite) throw const ValidationFailure(message: "That storage is read-only.");
    }

    final String token = ShareTokens.generate();
    final DateTime now = _clock.now();
    final Share share = Share(
      id: _ids.newId(),
      kind: kind,
      rootId: root.id,
      path: target.isRoot ? "/" : target.normalized,
      isDirectory: isDirectory,
      createdBy: creator.id,
      createdAt: now,
      tokenHash: ShareTokens.hash(token),
      label: cleanLabel,
      expiresAt: lifetime == null ? null : now.add(lifetime),
      passwordHash: password == null ? null : await _hasher.hash(password),
      maxUses: maxUses,
      maxFileBytes: maxFileBytes,
    );
    await _shares.add(share);
    return CreatedShare(share: share, token: token);
  }
}
