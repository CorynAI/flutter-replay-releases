import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../coryn.dart';
import '../state/coryn_state.dart';

/// Records uncaught Flutter framework and platform-dispatcher errors as Coryn events.
///
/// Dart errors do not crash the process, so the native crash reporting does not see them. Previous handlers keep
/// running; install it after other error reporters (for example Crashlytics), because a handler assigned later replaces
/// Coryn's. Error messages can contain user data: keep [includeMessages] off unless your messages are safe. In builds
/// with `--obfuscate`, recorded type names and Dart stack frames may be obfuscated; keep the matching
/// `--split-debug-info` files to symbolize stack traces.
abstract final class CorynErrorReporter {
  /// Event id of recorded errors.
  static const String eventId = 'FlutterError';
  static const int maxMessageLength = 2000;
  static const int maxStackLines = 40;
  static bool _isInstalled = false;

  /// Installs the handlers once. [includeMessages] adds the (truncated) error message; the type, library and stack
  /// frames are always recorded.
  static void install({bool includeMessages = false}) {
    if (_isInstalled) return;
    _isInstalled = true;
    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _record(details.exception, details.stack, details.library, isFatal: false, includeMessages: includeMessages);
      if (previousFlutterHandler != null) {
        previousFlutterHandler(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    final dispatcher = ui.PlatformDispatcher.instance;
    final previousDispatcherHandler = dispatcher.onError;
    dispatcher.onError = (Object error, StackTrace stack) {
      _record(error, stack, 'platform dispatcher', isFatal: true, includeMessages: includeMessages);
      return previousDispatcherHandler?.call(error, stack) ?? false;
    };
  }

  /// Never throws: a failure here must not keep the previous handlers from running.
  static void _record(
    Object error,
    StackTrace? stack,
    String? library, {
    required bool isFatal,
    required bool includeMessages,
  }) {
    try {
      final frames = stack?.toString().split('\n').where((String line) => line.trim().isNotEmpty).take(maxStackLines);
      final state = CorynJsonState(<String, Object?>{
        'type': error.runtimeType.toString(),
        'library': library,
        'uncaught': isFatal,
        if (includeMessages) 'message': _message(error),
        'stack': frames?.toList(growable: false),
      });
      Coryn.addEvent(eventId, state: state);
    } catch (_) {
      // A throwing toString() of the app's error, for example.
    }
  }

  static String _message(Object error) {
    final message = error.toString();
    return message.length > maxMessageLength ? message.substring(0, maxMessageLength) : message;
  }
}
