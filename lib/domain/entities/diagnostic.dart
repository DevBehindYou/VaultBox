enum DiagnosticStatus {
  ok,

  /// Works, but something deserves a look (unencrypted HTTP, no storage yet).
  warning,

  /// Broken: something won't work until it is fixed.
  problem,
}

/// The result of one health check.
///
/// [title] and [detail] are generic and safe to share; [subject] is the
/// person's own name for the thing checked (a storage location's name) and stays
/// out of the support bundle.
final class DiagnosticCheck {
  const DiagnosticCheck({
    required this.title,
    required this.status,
    required this.detail,
    this.subject,
    this.hint,
  });

  final String title;
  final DiagnosticStatus status;
  final String detail;
  final String? subject;

  /// What to do about it, for a warning or a problem.
  final String? hint;
}
