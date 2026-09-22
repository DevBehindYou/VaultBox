import "dart:async";

import "package:flutter_bloc/flutter_bloc.dart";

import "resource.dart";

/// Waits for the current or next non-loading state — the Cubit equivalent of
/// Riverpod's `ref.read(someProvider.future)`. Shared by every Cubit whose
/// state settles to a single value rather than repeating (a former
/// `FutureProvider`, or one derived from one).
mixin ResourceAwaiter<T> on Cubit<Resource<T>> {
  Future<T> current() async {
    final Resource<T> now = state;
    if (now is ResourceData<T>) return now.value;
    if (now is ResourceError<T>) throw now.error;
    final Resource<T> next = await stream.firstWhere(
      (Resource<T> s) => s is! ResourceLoading<T>,
    );
    if (next is ResourceError<T>) throw next.error;
    return (next as ResourceData<T>).value;
  }
}

/// Mirrors a `Stream<T>` as `Resource<T>` — the Cubit equivalent of a
/// (non-family) `StreamProvider`. One emission per stream event; loading only
/// shows before the first event, exactly like `StreamProvider`.
class ResourceStreamCubit<T> extends Cubit<Resource<T>> {
  ResourceStreamCubit(Stream<T> source) : super(const ResourceLoading()) {
    _subscription = source.listen(
      (T data) {
        if (!isClosed) emit(ResourceData<T>(data));
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!isClosed) emit(ResourceError<T>(error, stackTrace));
      },
    );
  }

  late final StreamSubscription<T> _subscription;

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}

/// Loads a value with a one-shot `Future<T> Function()` — the Cubit
/// equivalent of a `FutureProvider`. `refresh()` replaces
/// `ref.invalidate(someProvider)`: unlike the initial load, a refresh keeps
/// showing the last good value while the new one is in flight (it only
/// emits once the reload settles), which is what every call site here
/// already relied on via `.value ?? default` never seeing a reload flicker.
class ResourceFutureCubit<T> extends Cubit<Resource<T>>
    with ResourceAwaiter<T> {
  ResourceFutureCubit(this._load) : super(const ResourceLoading()) {
    unawaited(refresh());
  }

  final Future<T> Function() _load;

  Future<void> refresh() async {
    try {
      final T value = await _load();
      if (!isClosed) emit(ResourceData<T>(value));
    } on Object catch (error, stackTrace) {
      if (!isClosed) emit(ResourceError<T>(error, stackTrace));
    }
  }
}

/// Re-reads on a timer as well as on demand — the Cubit equivalent of the
/// `_polled()` helper the old `activityEventsProvider`-style providers used.
/// `refreshNow()` replaces `ref.invalidate(...)`: an out-of-band read that
/// doesn't disturb the periodic timer's schedule.
class PolledCubit<T> extends Cubit<Resource<T>> {
  PolledCubit(this._read, {this.every = const Duration(seconds: 3)})
    : super(const ResourceLoading()) {
    unawaited(refreshNow());
    _timer = Timer.periodic(every, (Timer _) => unawaited(refreshNow()));
  }

  final Future<T> Function() _read;
  final Duration every;
  late final Timer _timer;

  Future<void> refreshNow() async {
    try {
      final T value = await _read();
      if (!isClosed) emit(ResourceData<T>(value));
    } on Object catch (error, stackTrace) {
      if (!isClosed) emit(ResourceError<T>(error, stackTrace));
    }
  }

  @override
  Future<void> close() {
    _timer.cancel();
    return super.close();
  }
}
