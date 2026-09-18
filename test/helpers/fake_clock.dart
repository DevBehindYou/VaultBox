import "package:vaultbox/domain/repositories/clock.dart";

/// A clock that only moves when told to.
final class FakeClock implements Clock {
  FakeClock([DateTime? start]) : current = start ?? DateTime.utc(2026, 9, 19, 12);

  DateTime current;

  @override
  DateTime now() => current;

  void advance(Duration duration) => current = current.add(duration);
}
