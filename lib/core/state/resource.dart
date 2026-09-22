/// A Cubit-world stand-in for Riverpod's `AsyncValue`, kept only as wide as
/// this app's screens actually use: `.value` (last known data, or null),
/// `.when(loading:, error:, data:)` and `.maybeWhen(data:, orElse:)`. Every
/// reactive Cubit in this app (one that used to be a `StreamProvider` or
/// `FutureProvider`) emits `Resource<T>`, so screens migrating off Riverpod
/// keep the same three-state handling they already had.
sealed class Resource<T> {
  const Resource();

  /// The last known value. Null while loading, or on error with nothing
  /// loaded yet — callers that only care about "current value or a
  /// fallback" use `resource.value ?? someDefault`, exactly like
  /// `asyncValue.value ?? someDefault` before this rewrite.
  T? get value => null;

  R when<R>({
    required R Function() loading,
    required R Function(Object error, StackTrace stackTrace) error,
    required R Function(T value) data,
  }) {
    final Resource<T> self = this;
    if (self is ResourceData<T>) return data(self.value);
    if (self is ResourceError<T>) return error(self.error, self.stackTrace);
    return loading();
  }

  R maybeWhen<R>({
    R Function()? loading,
    R Function(Object error, StackTrace stackTrace)? error,
    R Function(T value)? data,
    required R Function() orElse,
  }) {
    final Resource<T> self = this;
    if (self is ResourceData<T> && data != null) return data(self.value);
    if (self is ResourceError<T> && error != null) {
      return error(self.error, self.stackTrace);
    }
    if (self is ResourceLoading<T> && loading != null) return loading();
    return orElse();
  }
}

final class ResourceLoading<T> extends Resource<T> {
  const ResourceLoading();
}

final class ResourceData<T> extends Resource<T> {
  const ResourceData(this._value);

  final T _value;

  @override
  T get value => _value;
}

final class ResourceError<T> extends Resource<T> {
  const ResourceError(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
