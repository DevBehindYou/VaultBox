/// Testable ID source (doc §03 "Service catalog": `IdGenerator`). Entities
/// that need a stable primary key (recycle items, shares, sessions, ...)
/// take one of these rather than calling a UUID package directly, so tests
/// can inject predictable IDs.
abstract interface class IdGenerator {
  String newId();
}
