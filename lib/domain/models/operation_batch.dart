import "../value_objects/storage_path.dart";

enum ItemOutcomeStatus { completed, failed, skipped }

/// The result for a single item within a multi-item operation. A batch of 48
/// items renders as "46 completed / 1 skipped / 1 failed" (kickoff §25),
/// never collapsed into one Boolean (doc §05 "Never collapse heterogeneous
/// batch results into one Boolean").
final class ItemOutcome {
  const ItemOutcome({
    required this.source,
    required this.status,
    this.target,
    this.userMessage,
  });

  const ItemOutcome.completed({required this.source, this.target})
    : status = ItemOutcomeStatus.completed,
      userMessage = null;

  const ItemOutcome.failed({
    required this.source,
    required String reason,
  }) : status = ItemOutcomeStatus.failed,
       target = null,
       userMessage = reason;

  const ItemOutcome.skipped({
    required this.source,
    required String reason,
  }) : status = ItemOutcomeStatus.skipped,
       target = null,
       userMessage = reason;

  final StoragePath source;
  final StoragePath? target;
  final ItemOutcomeStatus status;

  /// Human-readable reason, populated for failed/skipped items. Never a raw
  /// exception string (doc §20/kickoff §71).
  final String? userMessage;
}

/// Aggregate result of a batch operation (copy/move/delete/restore — doc
/// §04/§18 use cases). ADR-011: one item's failure never aborts unrelated
/// items unless the operation's own semantics require all-or-nothing.
final class OperationBatch {
  const OperationBatch({required this.outcomes});

  final List<ItemOutcome> outcomes;

  int get completedCount =>
      outcomes.where((ItemOutcome o) => o.status == ItemOutcomeStatus.completed).length;
  int get failedCount =>
      outcomes.where((ItemOutcome o) => o.status == ItemOutcomeStatus.failed).length;
  int get skippedCount =>
      outcomes.where((ItemOutcome o) => o.status == ItemOutcomeStatus.skipped).length;

  bool get hasFailures => failedCount > 0;
  bool get allCompleted => outcomes.isNotEmpty && failedCount == 0 && skippedCount == 0;

  /// Short summary line for a toast/snackbar, e.g. "46 completed · 1 skipped
  /// · 1 failed".
  String get summary {
    final List<String> parts = <String>[];
    if (completedCount > 0) parts.add("$completedCount completed");
    if (skippedCount > 0) parts.add("$skippedCount skipped");
    if (failedCount > 0) parts.add("$failedCount failed");
    if (parts.isEmpty) return "Nothing to do";
    return parts.join(" · ");
  }
}
