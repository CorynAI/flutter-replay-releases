/// Receives failures of the SDK's own code (never of the app's code) for the native error reporting.
abstract interface class CorynFailureReporter {
  /// Reports [reason], a fixed SDK text that never holds data, with the runtime type of [error] and the frames of
  /// [stack]. The error's message is never sent: it can carry private data.
  void reportFailure(String reason, Object? error, StackTrace? stack);
}
