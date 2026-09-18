import "../../core/errors/app_failure.dart";
import "../entities/account.dart";
import "../repositories/account_repository.dart";
import "../repositories/clock.dart";
import "../repositories/id_generator.dart";
import "../security/password_hasher.dart";
import "../security/password_policy.dart";
import "../security/username_policy.dart";

/// `CreateAdminAccount` — sets up the first (and, for now, only) account.
///
/// Order matters: validate the cheap things FIRST (username, password policy),
/// so a weak password never costs an Argon2 hash; hash; then store atomically,
/// refusing if an account already exists. The plaintext password is never
/// stored or logged.
final class CreateAdminAccount {
  const CreateAdminAccount(this._accounts, this._hasher, this._ids, this._clock);

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

    final Account account = Account(
      id: _ids.newId(),
      username: name,
      passwordHash: await _hasher.hash(password),
      createdAt: _clock.now(),
    );

    final Account? created = await _accounts.createFirst(account);
    if (created == null) {
      throw const ValidationFailure(message: "An admin account already exists.");
    }
    return created;
  }
}
