/// Where the package writes its diagnostics.
///
/// Voice control is largely invisible while it works and impossible to debug
/// when it does not, so the package logs generously. It has no opinion about
/// *where*: a consumer passes an adapter onto its own logging, or accepts the
/// default that discards everything.
abstract interface class VoiceLogger {
  void info(String message, [Map<String, Object?>? data]);

  void warn(String message, [Map<String, Object?>? data]);

  void error(String message, {Object? error, StackTrace? stackTrace});
}

/// Discards every message. The default, so a consumer that does not care about
/// diagnostics has nothing to configure.
final class SilentVoiceLogger implements VoiceLogger {
  const SilentVoiceLogger();

  @override
  void info(String message, [Map<String, Object?>? data]) {}

  @override
  void warn(String message, [Map<String, Object?>? data]) {}

  @override
  void error(String message, {Object? error, StackTrace? stackTrace}) {}
}
