import "../../core/errors/app_failure.dart";
import "../entities/access_rule.dart";
import "../entities/account.dart";
import "../repositories/account_repository.dart";
import "../repositories/clock.dart";
import "../repositories/id_generator.dart";
import "../repositories/share_repository.dart";
import "../security/password_hasher.dart";
import "../security/password_policy.dart";
import "../security/permission.dart";
import "../security/username_policy.dart";
import "../value_objects/storage_path.dart";

/// Adds a member account (someone who can log in but only reaches the folders
/// they are granted). Validate first, hash last — a weak password never costs
/// an Argon2 hash.
final class CreateUserAccount {
  const CreateUserAccount(this._accounts, this._hasher, this._ids, this._clock);

  final AccountRepository _accounts;
  final PasswordHasher _hasher;
  final IdGenerator _ids;
  final Clock _clock;

  Future<Account> call({required String username, required String password}) async {
    final String name = UsernamePolicy.normalize(username);
    final String? usernameProblem = UsernamePolicy.validate(name);
    if (usernameProblem != null) throw ValidationFailure(message: usernameProblem);
    final String? passwordProblem = PasswordPolicy.validate(password, username: name);
    if (passwordProblem != null) throw ValidationFailure(message: passwordProblem);

    final Account? created = await _accounts.create(
      Account(
        id: _ids.newId(),
        username: name,
        passwordHash: await _hasher.hash(password),
        createdAt: _clock.now(),
        role: AccountRole.member,
      ),
    );
    if (created == null) throw const ValidationFailure(message: "That username is already taken.");
    return created;
  }
}

/// Sets a new password (an admin resetting someone's, or anyone changing their
/// own). Ends every session the account has.
final class ChangePassword {
  const ChangePassword(this._accounts, this._hasher);

  final AccountRepository _accounts;
  final PasswordHasher _hasher;

  Future<void> call({required String accountId, required String newPassword}) async {
    final Account? account = await _accounts.findById(accountId);
    if (account == null) throw const ValidationFailure(message: "That account no longer exists.");

    final String? problem = PasswordPolicy.validate(newPassword, username: account.username);
    if (problem != null) throw ValidationFailure(message: problem);

    await _accounts.updatePasswordHash(accountId, await _hasher.hash(newPassword));
  }
}

/// Turns an account on or off. The last enabled admin can't be turned off: that
/// would leave nobody able to manage the server.
final class SetAccountEnabled {
  const SetAccountEnabled(this._accounts);

  final AccountRepository _accounts;

  Future<void> call({required String accountId, required bool enabled}) async {
    final Account? account = await _accounts.findById(accountId);
    if (account == null) throw const ValidationFailure(message: "That account no longer exists.");

    if (!enabled && account.isAdmin && account.isEnabled && await _accounts.countEnabledAdmins() <= 1) {
      throw const ValidationFailure(message: "This is the only admin — it can't be turned off.");
    }
    await _accounts.setEnabled(accountId, enabled: enabled);
  }
}

/// Removes an account, its folder grants and the links it made. Refuses to
/// remove the last enabled admin.
final class DeleteAccount {
  const DeleteAccount(this._accounts, this._shares);

  final AccountRepository _accounts;
  final ShareRepository _shares;

  Future<void> call({required String accountId}) async {
    final Account? account = await _accounts.findById(accountId);
    if (account == null) return;

    if (account.isAdmin && account.isEnabled && await _accounts.countEnabledAdmins() <= 1) {
      throw const ValidationFailure(message: "This is the only admin — it can't be removed.");
    }
    await _shares.deleteByCreator(accountId);
    await _accounts.delete(accountId);
  }
}

/// One folder grant as the person entered it.
final class AccessGrantInput {
  const AccessGrantInput({required this.rootId, required this.path, required this.permissions});

  final String rootId;

  /// Any folder path; normalised and validated here (`/` = the whole root).
  final String path;
  final Set<Permission> permissions;
}

/// Replaces a member's folder grants. Every path goes through [StoragePath]
/// like any other client path, and a grant must include `read` (write without
/// read is a mistake nobody wants).
final class SetAccessRules {
  const SetAccessRules(this._accounts, this._ids);

  final AccountRepository _accounts;
  final IdGenerator _ids;

  Future<void> call({required String accountId, required List<AccessGrantInput> grants}) async {
    final Account? account = await _accounts.findById(accountId);
    if (account == null) throw const ValidationFailure(message: "That account no longer exists.");
    if (account.isAdmin) {
      throw const ValidationFailure(message: "Admins already have access to everything.");
    }

    final List<AccessRule> rules = <AccessRule>[];
    final Set<String> seen = <String>{};
    for (final AccessGrantInput grant in grants) {
      if (grant.permissions.isEmpty) {
        throw const ValidationFailure(message: "Choose what this person may do in each folder.");
      }
      if (!grant.permissions.contains(Permission.read)) {
        throw const ValidationFailure(message: "Every folder needs at least “view” access.");
      }
      final StoragePath path;
      try {
        path = StoragePath.parseDecoded(grant.rootId, grant.path);
      } on AppFailure {
        throw const ValidationFailure(message: "That folder path isn't allowed.");
      }
      final String normalized = path.isRoot ? "/" : path.normalized;
      if (path.segments.isNotEmpty && path.segments.first.toLowerCase() == ".vaultbox") {
        throw const ValidationFailure(message: "That folder is Atomic Carton's own and can't be shared.");
      }
      if (!seen.add("${grant.rootId}|$normalized")) {
        throw const ValidationFailure(message: "That folder is listed twice.");
      }
      rules.add(
        AccessRule(
          id: _ids.newId(),
          accountId: accountId,
          rootId: grant.rootId,
          pathPrefix: normalized,
          permissions: Set<Permission>.of(grant.permissions),
        ),
      );
    }
    await _accounts.replaceRules(accountId, rules);
  }
}
