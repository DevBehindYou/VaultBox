import "package:flutter/material.dart";

import "../../../../domain/value_objects/write_mode.dart";

/// Asks for one policy covering every conflicting name in the batch —
/// "Replace all" / "Keep both" / "Skip all" — rather than the mockup's
/// per-item resolution with an "apply to all" toggle.
///
/// This is a deliberate scope cut (docs/IMPLEMENTATION_PLAN.md §H), not an
/// oversight: per-item resolution needs a stepper UI that shows one conflict
/// at a time with its own apply-to-all checkbox, which is meaningfully more
/// surface for a case ("some of my 40 selected files happen to already exist
/// at the destination") that a single upfront choice already handles
/// correctly for the overwhelming majority of real batches. Kickoff §5 asks
/// for "clearer hierarchy" over "more dashboard" in exactly this kind of
/// trade-off.
///
/// Returns `null` if the person cancelled — callers must treat that as
/// "abort the whole operation", not "proceed with a default".
Future<ConflictPolicy?> showConflictResolutionDialog(
  BuildContext context, {
  required List<String> conflictingNames,
}) {
  final int count = conflictingNames.length;
  final String preview = conflictingNames.take(3).join(", ");
  final String suffix = count > 3 ? ", and ${count - 3} more" : "";

  return showDialog<ConflictPolicy>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(
        count == 1
            ? "\"$preview\" already exists here"
            : "$count items already exist here",
      ),
      content: Text(
        count == 1
            ? "What should happen to it?"
            : "$preview$suffix. What should happen to these?",
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text("Cancel"),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(ConflictPolicy.skip),
          child: const Text("Skip these"),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(ConflictPolicy.keepBoth),
          child: const Text("Keep both"),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(ConflictPolicy.replace),
          child: const Text("Replace"),
        ),
      ],
    ),
  );
}
