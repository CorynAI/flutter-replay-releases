import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'capture/coryn_capture_stats.dart';
import 'configuration.dart';
import 'errors/coryn_app_errors.dart';
import 'errors/coryn_error_reporter.dart';
import 'internal/coryn_runtime.dart';
import 'network/coryn_api_request.dart';
import 'screens/coryn_screen_registration.dart';
import 'state/coryn_state.dart';

/// Entry point of the Coryn Session Replay SDK for Flutter. Mirrors the Android `Coryn` facade.
///
/// Android only for now: on other platforms every call is a no-op and the widgets only render their child. Only the
/// root (UI) isolate records; in other isolates (`compute`, `Isolate.run`) every call is a no-op too.
abstract final class Coryn {
  static CorynRuntime get _runtime => CorynRuntime.instance;

  /// Whether this platform records sessions.
  static bool get isSupported => _runtime.platform.isSupported;

  /// Initialises the SDK with [apiKey]. The first `init` in a process wins, including a native `Coryn.init` in
  /// `Application.onCreate` (recommended: it also covers crashes before the Flutter engine starts).
  ///
  /// It also records uncaught Dart errors as `FlutterError` events by chaining `FlutterError.onError` and
  /// `PlatformDispatcher.instance.onError`; call it after other error reporters set theirs. Messages are recorded only
  /// with [CorynConfiguration.includeErrorMessages]. At most 10 errors are recorded in each one-second window; all of
  /// them still reach the previous handlers.
  static Future<void> init(
    String apiKey, {
    CorynConfiguration? configuration,
    CorynCaptureOptions captureOptions = const CorynCaptureOptions(),
  }) async {
    _runtime.capture.options = captureOptions;
    if (!await _runtime.ensureAttached()) return;
    CorynErrorReporter.install(includeMessages: configuration?.includeErrorMessages ?? false);
    await _runtime.reportingFailures('init', () => _runtime.platform.init(apiKey, configuration));
    _runtime.onInitialized();
  }

  /// Requests recording. The first request in a process wins. [onRecordingStarted] receives the session id once the
  /// native session starts (immediately if it already has), for correlation with other analytics.
  static Future<void> startRecording({
    String? delayReason,
    CorynRecordingConfiguration? configuration,
    void Function(String sessionId)? onRecordingStarted,
  }) async {
    if (!await _runtime.ensureAttached()) return;
    if (onRecordingStarted != null) _runtime.addSessionListener(onRecordingStarted);
    await _runtime.reportingFailures(
      'startRecording',
      () => _runtime.platform.startRecording(delayReason, configuration),
    );
  }

  /// Stops recording; what was recorded is kept. Recording cannot be restarted in this process (native contract).
  static Future<void> stopRecording([String? reason]) async {
    try {
      if (await _runtime.ensureAttached()) {
        await _runtime.reportingFailures('stopRecording', () => _runtime.platform.stopRecording(reason));
      }
    } finally {
      _runtime.onStopRequested();
    }
  }

  /// Sets the ID of the signed-in user of your app, so that the recordings of one person can be found and erased on
  /// request. Pass an internal account ID, not an email, phone number or name, and `null` when the user signs out.
  ///
  /// Every recording lists the user ID set when it started and every other distinct user ID set while it was recorded.
  /// Setting the same ID again does nothing. More than 10 distinct user IDs in one recording cancel the recording.
  static void setUserId(String? userId) {
    if (!isSupported) return;
    unawaited(_call('setUserId', () => _runtime.platform.setUserId(userId)));
  }

  /// Id of the current native session, once it started.
  static String? get sessionId => _runtime.sessionId;

  /// Whether a native session is recording now, as far as this isolate knows (always `false` outside the root
  /// isolate). HTTP integrations skip all work while it is `false`, like the Android OkHttp interceptor.
  static bool get isRecording {
    if (!isSupported) return false;
    _runtime.attachInBackground();
    return _runtime.sessionId != null;
  }

  /// Registers a screen until [CorynScreenRegistration.unregister]. Prefer `CorynNavigatorObserver` or `CorynScreen`.
  ///
  /// [isDialog] tells whether the screen is a dialog or a bottom sheet shown above another screen.
  /// [arguments] values must be `String`, `num` or `bool`; they are recorded as-is, so never pass private data.
  static CorynScreenRegistration registerScreen(String name, {required bool isDialog, Map<String, Object>? arguments}) {
    return CorynScreenRegistration.register(_runtime, name, isDialog, arguments);
  }

  /// Adds (or replaces) the provider of [stateId]. Call [removeState] when it is no longer valid.
  static void provideState(String stateId, CorynStateProvider<CorynState> provider) {
    if (!isSupported) return;
    _runtime.attachInBackground();
    _runtime.sampler.provide(stateId, provider);
  }

  /// Removes the provider of [stateId]; its state ends on the timeline. With [provider], removes it only while it is
  /// still the provider of [stateId], so a newer registration of the same id stays (the native `expectedProvider`).
  static void removeState(String stateId, {CorynStateProvider<CorynState>? provider}) {
    if (!isSupported) return;
    _runtime.sampler.remove(stateId, expected: provider);
  }

  /// Adds an event, optionally with a [state]. [timePassed] says how long ago it happened.
  static void addEvent(String eventId, {CorynState? state, Duration timePassed = Duration.zero}) {
    if (!isSupported) return;
    // Native dates the event when the call arrives, which may wait for attach.
    final sinceCall = Stopwatch()..start();
    final stateJson = state == null ? null : _encodeEventState(eventId, state);
    unawaited(
      _call('addEvent', () {
        final timePassedMs = (timePassed + sinceCall.elapsed).inMilliseconds;
        return _runtime.platform.addEvent(eventId, stateJson, timePassedMs);
      }),
    );
  }

  /// Reports a completed HTTP request. UI hiding does not mask these fields; see [CorynApiRequest].
  static void addApiRequest(CorynApiRequest request) {
    if (!isSupported) return;
    unawaited(_call('addApiRequest', () => _runtime.platform.addApiRequest(request)));
  }

  /// Shows a native Android Toast tracked by the SDK (`Coryn.acceptToast`). The native SDK draws accepted toasts only
  /// in its own View capture, so the toast is absent from Flutter UI captures.
  static void showToast(String text, {bool isLong = false}) {
    if (!isSupported) return;
    unawaited(_call('showToast', () => _runtime.platform.showToast(text, isLong)));
  }

  /// Dart capture counters (timings, outcomes) for diagnostics and benchmarks.
  static CorynCaptureStats get captureStats => _runtime.capture.stats;

  /// Native bridge counters for diagnostics and benchmarks.
  static Future<Map<String, Object?>> debugStats() async {
    if (!await _runtime.ensureAttached()) return const <String, Object?>{};
    return _runtime.reportingFailures('debugStats', _runtime.platform.debugStats);
  }

  static String? _encodeEventState(String eventId, CorynState state) {
    try {
      return jsonEncode(state.toJson());
    } catch (error, stack) {
      presentAppError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'coryn_replay',
          context: ErrorDescription('while encoding the state of Coryn event "$eventId"'),
          silent: kReleaseMode,
        ),
      );
      return null;
    }
  }

  /// Fire-and-forget calls never throw into the app: native rejects them before `Coryn.init`, for example.
  static Future<void> _call(String name, Future<void> Function() action) async {
    try {
      if (await _runtime.ensureAttached()) await action();
    } catch (error, stack) {
      _runtime.reportCallFailure(name, error, stack);
    }
  }
}
