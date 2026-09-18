/// How a write should behave when the target path already has something at
/// it. Used by `StorageBackend.openWrite` and by conflict-resolution flows
/// (doc §11 "Conflict resolution": Replace / Keep Both / Skip / Apply to all).
enum WriteMode {
  /// Fail if the target already exists.
  create,

  /// Overwrite the target if it exists.
  replace,

  /// Caller has already resolved the name (e.g. `filename (1).ext`) — write
  /// as a brand-new entry.
  keepBoth,
}

/// User's resolution choice when a batch operation hits a naming conflict.
/// Kept separate from [WriteMode] because it's a UI-facing decision that maps
/// down to a [WriteMode] per item, and can carry "apply to all" state that
/// [WriteMode] itself has no business knowing about.
enum ConflictPolicy { replace, keepBoth, skip }
