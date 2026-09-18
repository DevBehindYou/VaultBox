/// Testable time source (doc §03 "Service catalog": `ClockService`; doc §59
/// "Test-first architecture" calls out `FakeClock` explicitly as a required
/// fake). Nothing in the domain/use-case layer should call `DateTime.now()`
/// directly — inject this instead so recycle-bin purge deadlines, session
/// expiry, etc. are deterministic in tests.
abstract interface class Clock {
  DateTime now();
}
