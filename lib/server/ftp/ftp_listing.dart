/// One entry of a folder listing, ready to be written in FTP's formats.
final class FtpEntry {
  const FtpEntry({
    required this.name,
    required this.isDirectory,
    this.size,
    this.modified,
    this.canWrite = false,
    this.canDelete = false,
  });

  final String name;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;
  final bool canWrite;
  final bool canDelete;
}

const List<String> _months = <String>["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

String _two(int n) => n.toString().padLeft(2, "0");

/// `20260920123045` — the time format of MDTM and MLSD (always UTC).
String ftpTimestamp(DateTime time) {
  final DateTime utc = time.toUtc();
  return "${utc.year.toString().padLeft(4, "0")}${_two(utc.month)}${_two(utc.day)}"
      "${_two(utc.hour)}${_two(utc.minute)}${_two(utc.second)}";
}

/// A line of `LIST` output in the widely understood `ls -l` layout:
/// `drwxr-xr-x 1 vaultbox vaultbox 0 Sep 20 12:30 Photos`.
///
/// Recent entries show a time, older ones a year, as `ls` does. The owner is a
/// fixed placeholder: FTP clients only display it.
String unixListLine(FtpEntry entry, DateTime now) {
  final String kind = entry.isDirectory ? "d" : "-";
  final String perms = entry.canWrite ? "rwxr-xr-x" : "r-xr-xr-x";
  final String size = (entry.size ?? 0).toString().padLeft(12);
  final DateTime when = (entry.modified ?? now).toUtc();
  final Duration age = now.toUtc().difference(when);
  final String stamp = age.inDays > 180 || age.isNegative && age.inDays < -1
      ? " ${when.year.toString().padLeft(4)}"
      : "${_two(when.hour)}:${_two(when.minute)}";
  return "$kind$perms 1 vaultbox vaultbox $size ${_months[when.month - 1]} ${when.day.toString().padLeft(2)} $stamp ${entry.name}";
}

/// A line of `MLSD` output: machine-readable facts, then the name.
/// `type=dir;modify=20260920123000;perm=elcmpd; Photos`
String mlsxLine(FtpEntry entry) {
  final StringBuffer facts = StringBuffer("type=${entry.isDirectory ? "dir" : "file"};");
  if (!entry.isDirectory && entry.size != null) facts.write("size=${entry.size};");
  if (entry.modified != null) facts.write("modify=${ftpTimestamp(entry.modified!)};");
  facts.write("perm=${_permissions(entry)}; ${entry.name}");
  return facts.toString();
}

String _permissions(FtpEntry entry) {
  if (entry.isDirectory) {
    // e: enter, l: list, c: create files, m: make folders, p: purge inside, d: delete it.
    return "el${entry.canWrite ? "cm" : ""}${entry.canDelete ? "pd" : ""}";
  }
  // r: read, w: write, a: append, d: delete, f: rename.
  return "r${entry.canWrite ? "waf" : ""}${entry.canDelete ? "d" : ""}";
}

/// Just the names, one per line (`NLST`).
String nameOnlyLine(FtpEntry entry) => entry.name;
