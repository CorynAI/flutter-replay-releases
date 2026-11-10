import 'package:flutter/foundation.dart';

/// Hands an app callback's failure to the app's error handling. A throwing `FlutterError.onError` is the app's too: it
/// must not stop the SDK's work or be reported as an SDK failure.
void presentAppError(FlutterErrorDetails details) {
  try {
    FlutterError.reportError(details);
  } catch (_) {
    // The app's error handler failed.
  }
}
