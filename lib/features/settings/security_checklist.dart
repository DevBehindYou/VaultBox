import "../../domain/entities/server_config.dart";
import "../../domain/entities/share.dart";

/// How a protection line reads.
enum CheckLevel {
  /// In place.
  good,

  /// Worth a look — not necessarily wrong, but a person should know.
  notice,
}

final class SecurityItem {
  const SecurityItem({required this.title, required this.detail, required this.level});

  final String title;
  final String detail;
  final CheckLevel level;

  bool get isGood => level == CheckLevel.good;
}

/// The protections that hold today, judged from the real settings — never from
/// a promise. Some lines are always good because the server can't be run
/// without them (every request needs a sign-in or a link secret); they are
/// listed so a person can see what is being enforced for them.
List<SecurityItem> buildSecurityChecklist({
  required ServerConfig config,
  required bool adminExists,
  required List<Share> shares,
  required DateTime now,
}) {
  final int openLinks = shares.where((Share s) => s.isActive(now) && !s.hasPassword).length;

  return <SecurityItem>[
    if (config.httpEnabled)
      const SecurityItem(
        title: "Encryption",
        detail: "Plain HTTP is on. Passwords and files sent over it can be read by others on your Wi-Fi.",
        level: CheckLevel.notice,
      )
    else if (config.httpsEnabled)
      const SecurityItem(
        title: "Encryption",
        detail: "HTTPS is the only way in, so what travels to and from your phone is encrypted.",
        level: CheckLevel.good,
      )
    else
      const SecurityItem(
        title: "Encryption",
        detail: "No connection type is switched on, so the server can't start.",
        level: CheckLevel.notice,
      ),
    if (adminExists)
      const SecurityItem(
        title: "Admin sign-in",
        detail: "An admin account guards the server. Passwords are stored only as salted Argon2id hashes.",
        level: CheckLevel.good,
      )
    else
      const SecurityItem(
        title: "Admin sign-in",
        detail: "There is no admin account yet, so nobody can sign in.",
        level: CheckLevel.notice,
      ),
    SecurityItem(
      title: "Network reach",
      detail: config.allowNetworkAccess
          ? "Devices on your local network can reach the server. It is never opened to the internet."
          : "Only this phone can reach the server.",
      level: CheckLevel.good,
    ),
    const SecurityItem(
      title: "Guess protection",
      detail: "Repeated wrong passwords lock sign-in, per account and per address, for longer each time.",
      level: CheckLevel.good,
    ),
    const SecurityItem(
      title: "No anonymous access",
      detail: "Every request needs a sign-in or a link's secret. There is no guest access.",
      level: CheckLevel.good,
    ),
    if (openLinks > 0)
      SecurityItem(
        title: "Links",
        detail: openLinks == 1
            ? "1 active link has no password: anyone who gets its address can use it."
            : "$openLinks active links have no password: anyone who gets their addresses can use them.",
        level: CheckLevel.notice,
      )
    else
      const SecurityItem(
        title: "Links",
        detail: "Every active link is protected by a password, or there are none.",
        level: CheckLevel.good,
      ),
  ];
}
