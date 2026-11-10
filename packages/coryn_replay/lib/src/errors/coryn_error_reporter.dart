import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../coryn.dart';
import '../state/coryn_state.dart';

/// Records uncaught Flutter framework and platform-dispatcher errors as Coryn events. `Coryn.init` installs it.
///
/// Dart errors do not crash the process, so the native crash reporting does not see them. Previous handlers keep
/// running; a handler assigned later without chaining replaces Coryn's.
///
/// Errors that Coryn's packages caught in app callbacks and present themselves are not recorded: they are handled, and
/// their stack can be app-supplied text.
///
/// At most [maxEventsPerWindow] errors are recorded in each one-second window, so an error repeated every frame (a
/// failing animation listener or paint) costs little; the others, distinct ones too, still reach the previous handlers.
abstract final class CorynErrorReporter {
  /// Event id of recorded errors.
  static const String eventId = 'FlutterError';
  static const int maxMessageLength = 2000;
  static const int maxStackLines = 40;
  static const int maxEventsPerWindow = 10;
  static const Duration window = Duration(seconds: 1);
  static final Stopwatch _clock = Stopwatch()..start();

  /// Current time for the recording window; tests replace it.
  @visibleForTesting
  static Duration Function() now = _clockElapsed;
  static Duration _windowStart = Duration.zero;
  static int _windowCount = 0;
  static bool _isInstalled = false;
  static FlutterExceptionHandler? _previousFlutterHandler;
  static ui.ErrorCallback? _previousDispatcherHandler;
  static FlutterExceptionHandler? _flutterHandler;
  static ui.ErrorCallback? _dispatcherHandler;

  /// Installs the handlers once per isolate. [includeMessages] adds the (truncated) error message to recorded errors,
  /// which always hold the type, library and stack frames.
  static void install({required bool includeMessages}) {
    if (_isInstalled) return;
    _isInstalled = true;
    final previousFlutterHandler = _previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = _flutterHandler = (FlutterErrorDetails details) {
      if (!_isPresentedByCoryn(details)) {
        _record(details.exception, details.stack, details.library, isFatal: false, includeMessages: includeMessages);
      }
      previousFlutterHandler?.call(details);
    };
    final dispatcher = ui.PlatformDispatcher.instance;
    final previousDispatcherHandler = _previousDispatcherHandler = dispatcher.onError;
    dispatcher.onError = _dispatcherHandler = (Object error, StackTrace stack) {
      _record(error, stack, 'platform dispatcher', isFatal: true, includeMessages: includeMessages);
      return previousDispatcherHandler?.call(error, stack) ?? false;
    };
  }

  /// Restores the handlers that Coryn still owns and allows another install, for `CorynRuntime.debugReset`.
  static void debugReset() {
    now = _clockElapsed;
    _windowStart = now();
    _windowCount = 0;
    if (!_isInstalled) return;
    if (FlutterError.onError == _flutterHandler) FlutterError.onError = _previousFlutterHandler;
    final dispatcher = ui.PlatformDispatcher.instance;
    if (dispatcher.onError == _dispatcherHandler) dispatcher.onError = _previousDispatcherHandler;
    _isInstalled = false;
    _previousFlutterHandler = null;
    _previousDispatcherHandler = null;
    _flutterHandler = null;
    _dispatcherHandler = null;
  }

  static Duration _clockElapsed() => _clock.elapsed;

  /// Takes one recording from the window's budget; an attempt counts even if its recording fails.
  static bool _takeWindowBudget() {
    final time = now();
    if (time - _windowStart >= window) {
      _windowStart = time;
      _windowCount = 0;
    }
    if (_windowCount >= maxEventsPerWindow) return false;
    _windowCount++;
    return true;
  }

  static bool _isPresentedByCoryn(FlutterErrorDetails details) => details.library?.startsWith('coryn_replay') ?? false;

  /// Never throws: a failure here must not keep the previous handlers from running.
  static void _record(
    Object error,
    StackTrace? stack,
    String? library, {
    required bool isFatal,
    required bool includeMessages,
  }) {
    try {
      if (!_takeWindowBudget()) return;
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
