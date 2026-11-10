import '../internal/coryn_runtime.dart';

/// Failures of Coryn's own packages for the native error reporting: each reason once per isolate, only the error's
/// type and stack frames, never its message. A no-op outside the root isolate and on unsupported platforms.
abstract final class CorynSdkFailures {
  /// [reason] is a fixed text of the reporting package (never request or app data).
  static void report(String reason, Object? error, StackTrace? stack) {
    CorynRuntime.instance.reportFailure(reason, error, stack);
  }
}
