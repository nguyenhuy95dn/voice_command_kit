import 'dart:async';

/// Simple sequential executor to serialize async operations.
final class AsyncLock {
  Future<void>? _lockFuture;

  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _lockFuture;
    final completer = Completer<void>();
    _lockFuture = completer.future;

    try {
      if (previous != null) {
        await previous.catchError((_) {});
      }
      return await action();
    } finally {
      completer.complete();
      if (_lockFuture == completer.future) {
        _lockFuture = null;
      }
    }
  }
}
