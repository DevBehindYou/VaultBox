import "package:uuid/uuid.dart";

import "../../domain/repositories/clock.dart";
import "../../domain/repositories/id_generator.dart";

/// Production [Clock]. Tests use a `FakeClock` instead (doc §59).
final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// Production [IdGenerator] — UUID v4.
final class UuidIdGenerator implements IdGenerator {
  UuidIdGenerator();

  final Uuid _uuid = const Uuid();

  @override
  String newId() => _uuid.v4();
}
