import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../capture/coryn_capture_scheduler.dart';
import '../capture/coryn_screen_text.dart';
import '../capture/coryn_touch_tracker.dart';
import '../errors/coryn_app_errors.dart';
import '../errors/coryn_error_reporter.dart';
import '../platform/coryn_platform.dart';
import '../platform/method_channel_coryn_platform.dart';
import '../platform/noop_coryn_platform.dart';
import '../screens/coryn_screen_registration.dart';
import '../state/coryn_state_sampler.dart';

/// Wires the platform bridge, state sampler and capture scheduler of the root isolate.
final class CorynRuntime
    with WidgetsBindingObserver
    implements CorynPlatformListener, CorynStateBatchSink, CorynTouchSink {
  CorynRuntime._(this.platform) {
    sampler = CorynStateSampler(this);
    capture = CorynCaptureScheduler(platform, this);
    touches = CorynTouchTracker(this);
  }

  /// Distinct SDK failure reasons attempted per isolate; failed attempts and later occurrences are not retried.
  static const int maxReportedFailures = 20;

  /// Stack lines sent per failure; native keeps 1,000 characters of a failure's details.
  static const int maxStackLines = 20;

  static CorynRuntime? _instance;

  /// The runtime of this isolate.
  static CorynRuntime get instance => _instance ??= CorynRuntime._(_defaultPlatform());

  /// Replaces the runtime for tests.
  @visibleForTesting
  static void debugReset(CorynPlatform platform) {
    _instance?._dispose();
    CorynErrorReporter.debugReset();
    _instance = CorynRuntime._(platform);
  }

  /// Only the root (UI) isolate records: other isolates have no UI and cannot receive native callbacks.
  static CorynPlatform _defaultPlatform() {
    final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final isRecordingIsolate = isAndroid && ServicesBinding.rootIsolateToken != null;
    return isRecordingIsolate ? MethodChannelCorynPlatform() : const NoopCorynPlatform();
  }

  final CorynPlatform platform;
  late final CorynStateSampler sampler;
  late final CorynCaptureScheduler capture;
  late final CorynTouchTracker touches;
  final CorynScreenTextReader screenText = CorynScreenTextReader();
  final List<void Function(String sessionId)> _sessionListeners = <void Function(String sessionId)>[];
  Future<bool>? _attached;
  String? _sessionId;
  bool _isRecordingStopped = false;

  /// Id of the native session, once it started.
  String? get sessionId => _sessionId;

  /// Attaches to the native plugin once per isolate and completes with whether native calls can be made. Safe to call
  /// repeatedly.
  Future<bool> ensureAttached() => _attached ??= _attach();

  /// Starts attaching for callers that do not wait; an attach failure was reported and reaches only awaiting callers.
  void attachInBackground() => ensureAttached().ignore();

  /// Touch regions are tracked from here on; they cover the surface only when no scene of this isolate was submitted
  /// yet.
  Future<bool> _attach() async {
    if (!platform.isSupported) return false;
    final binding = WidgetsFlutterBinding.ensureInitialized();
    final isBeforeFirstScene = binding.rootElement == null;
    binding.addObserver(this);
    SchedulerBinding.instance.addPersistentFrameCallback((_) => _onFrame());
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerEvent);
    _isPointerRouteAdded = true;
    _applyLifecycle(binding.lifecycleState);
    final CorynNativeStatus status;
    try {
      status = await platform.attach(this);
    } on MissingPluginException catch (error) {
      // An engine without registered plugins (custom add-to-app engine, a plain unit test): record nothing.
      logFailureOnce('attach', error);
      return false;
    } catch (error, stack) {
      reportCallFailure('attach', error, stack);
      rethrow;
    }
    touches.grantCoverage(isBeforeFirstScene && status.isSurfaceFresh);
    if (status.isRecordingStopped) {
      onRecordingStopped();
      return true;
    }
    if (!_isGeometryEventSeen) capture.geometryRevision = status.geometryRevision;
    if (!_isSurfaceEventSeen) capture.isSurfaceLive = status.isSurfaceLive;
    final targetFps = status.captureTargetFps;
    if (targetFps != null && !_isRecordingStopped && !_isCaptureEventSeen) capture.start(targetFps);
    final sessionId = status.sessionId;
    if (sessionId != null) onRecordingStarted(sessionId);
    return true;
  }

  final Set<String> _loggedFailures = <String>{};
  bool _isInitialized = false;

  /// Screens whose registration failed before `Coryn.init` (native rejects them); registered once after init.
  final Set<CorynScreenRegistration> _screensAwaitingInit = <CorynScreenRegistration>{};

  /// Remembers [registration] for one retry after `Coryn.init`. Failures after init are final; a registration that
  /// already ended (before its failure arrived) is not remembered.
  void registerAfterInit(CorynScreenRegistration registration) {
    if (!_isInitialized && !registration.isUnregistered) _screensAwaitingInit.add(registration);
  }

  /// Screens waiting for `Coryn.init`, for tests.
  @visibleForTesting
  int get screensAwaitingInitCount => _screensAwaitingInit.length;

  /// [registration] was unregistered; it is not registered after init.
  void cancelAfterInit(CorynScreenRegistration registration) => _screensAwaitingInit.remove(registration);

  /// Dart `Coryn.init` succeeded: register the screens that native rejected before it.
  void onInitialized() {
    if (_isInitialized) return;
    _isInitialized = true;
    final screens = List<CorynScreenRegistration>.of(_screensAwaitingInit);
    _screensAwaitingInit.clear();
    for (final screen in screens) {
      screen.retryAfterInit();
    }
  }

  /// Fire-and-forget calls never surface errors (native rejects calls before `Coryn.init`; an uncaught error would also
  /// reach the error hooks of `Coryn.init`, which record it with another call). Debug builds print the first failure
  /// per call.
  void logFailureOnce(String call, Object error) {
    if (kReleaseMode || !_loggedFailures.add(call)) return;
    debugPrint('Coryn: $call failed: $error');
  }

  /// A platform call failed. Native reports its own failures ([PlatformException]) and a missing plugin is expected, so
  /// only a failure before native handled the call (codec, channel) is reported here.
  void reportCallFailure(String call, Object error, StackTrace stack) {
    logFailureOnce(call, error);
    final isHandledByNative = error is PlatformException || error is MissingPluginException;
    if (!isHandledByNative) reportFailure('call $call', error, stack);
  }

  /// Runs an awaited platform call: its failure is reported like [reportCallFailure] and still reaches the caller.
  Future<T> reportingFailures<T>(String call, Future<T> Function() action) async {
    try {
      return await action();
    } catch (error, stack) {
      reportCallFailure(call, error, stack);
      rethrow;
    }
  }

  final Set<String> _reportedFailures = <String>{};

  /// Sends each reason once per isolate, at most [maxReportedFailures], straight to the platform (also when attach
  /// failed). Non-release builds also hand it to [FlutterError.reportError]. Reporting is terminal: nothing here throws
  /// or is reported again.
  @override
  void reportFailure(String reason, Object? error, StackTrace? stack) {
    final isNew = _reportedFailures.length < maxReportedFailures && _reportedFailures.add(reason);
    if (!isNew || !platform.isSupported) return;
    try {
      final frames = stack?.toString().split('\n').where((String line) => line.trim().isNotEmpty).take(maxStackLines);
      platform.reportFailure(reason, error?.runtimeType.toString(), frames?.join('\n')).ignore();
      if (!kReleaseMode) _presentFailure(reason, error, stack);
    } catch (_) {
      // A failing platform call or error handler: reporting must not fail its caller.
    }
  }

  static void _presentFailure(String reason, Object? error, StackTrace? stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error ?? StateError('Coryn SDK failure: $reason'),
        stack: stack,
        library: 'coryn_replay',
        context: ErrorDescription('in the Coryn SDK ($reason)'),
      ),
    );
  }

  void _dispose() {
    capture.stop();
    sampler.clear();
    if (_attached == null) return;
    WidgetsBinding.instance.removeObserver(this);
    if (!_isPointerRouteAdded) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointerEvent);
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
  }

  bool _isPointerRouteAdded = false;

  void _onFrame() {
    capture.onFrame();
    try {
      touches.onFrame(capture.root, SchedulerBinding.instance.currentSystemFrameTimeStamp);
    } catch (error, stack) {
      touches.markFailed();
      reportFailure('touch: frame', error, stack);
    }
  }

  void _onFrameTimings(List<ui.FrameTiming> timings) {
    try {
      touches.onFrameTimings(timings);
    } catch (error, stack) {
      touches.markFailed();
      reportFailure('touch: timings', error, stack);
    }
  }

  void _onPointerEvent(PointerEvent event) {
    try {
      touches.handleEvent(event, capture.root);
    } catch (error, stack) {
      touches.markFailed();
      reportFailure('touch: event', error, stack);
    }
  }

  @override
  bool get isRecording => _sessionId != null && !_isRecordingStopped;

  @override
  void sendTouch(int action, int actionPointer, List<num> pointers, int eventTimeMs) {
    platform.sendTouch(action, actionPointer, pointers, eventTimeMs).catchError((Object error, StackTrace stack) {
      reportCallFailure('touch', error, stack);
    });
  }

  /// Answers with the visible text of the captured root (none without a root). A failed read is not answered, so
  /// native drops its last sample when the request expires.
  @override
  void onScreenTextRequest(int requestId) {
    final root = capture.root;
    final List<List<Object>> items;
    try {
      items = root == null || !root.attached ? const <List<Object>>[] : screenText.read(root, capture.frameCount);
    } catch (error, stack) {
      reportFailure('screen text: read', error, stack);
      return;
    }
    platform.sendScreenText(requestId, items).catchError((Object error, StackTrace stack) {
      reportCallFailure('screenText', error, stack);
    });
  }

  /// Calls [listener] once the native session started (immediately when it already has); never after a terminal stop.
  void addSessionListener(void Function(String sessionId) listener) {
    final sessionId = _sessionId;
    if (sessionId != null) {
      _notifySessionListener(listener, sessionId);
      return;
    }
    if (_isRecordingStopped) return;
    _sessionListeners.add(listener);
  }

  /// Listeners waiting for a session, for tests.
  @visibleForTesting
  int get sessionListenerCount => _sessionListeners.length;

  /// Dart's `stopRecording` is terminal in the native SDK: stop producing captures and states for good. Nothing records
  /// from now on, also before native confirms the stop with `recordingStopped`.
  void onStopRequested() {
    _isRecordingStopped = true;
    _sessionId = null;
    capture.stop();
    sampler.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _applyLifecycle(state);

  /// Capture also pauses while inactive (Android's onPause): onStop hides the view right after sending `paused`, and an
  /// image snapshot taken without a surface can fault natively (Impeller's OpenGL ES backend).
  void _applyLifecycle(AppLifecycleState? state) {
    final isPaused = switch (state) {
      AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => true,
      AppLifecycleState.resumed || AppLifecycleState.inactive || null => false,
    };
    sampler.isPaused = isPaused;
    capture.isPaused = isPaused || state == AppLifecycleState.inactive;
  }

  /// A capture start or stop that arrived while attaching is newer than the attach reply's capture rate.
  bool _isCaptureEventSeen = false;

  @override
  void onCaptureStart(double targetFps) {
    _isCaptureEventSeen = true;
    if (_isRecordingStopped) return;
    capture.start(targetFps);
  }

  @override
  void onCaptureStop() {
    _isCaptureEventSeen = true;
    capture.stop();
  }

  /// A geometry event that arrived while attaching is newer than the attach reply's revision.
  bool _isGeometryEventSeen = false;

  @override
  void onCaptureInvalidate(int geometryRevision) {
    _isGeometryEventSeen = true;
    capture.invalidate(geometryRevision);
  }

  @override
  void onCaptureReady() => capture.onNativeReady();

  /// A surface event that arrived while attaching is newer than the attach reply's snapshot.
  bool _isSurfaceEventSeen = false;

  @override
  void onSurfaceLive(bool isLive) {
    _isSurfaceEventSeen = true;
    capture.isSurfaceLive = isLive;
    if (!isLive) touches.onSurfaceDiscarded();
  }

  /// The native session started: sample providers from now on. A start that native announced before this isolate's
  /// stop reached it still reaches the listeners (the session's data exists), but nothing records any more.
  @override
  void onRecordingStarted(String sessionId) {
    if (!_isRecordingStopped) {
      _sessionId = sessionId;
      sampler.isRecording = true;
    }
    final listeners = List<void Function(String sessionId)>.of(_sessionListeners);
    _sessionListeners.clear();
    for (final listener in listeners) {
      _notifySessionListener(listener, sessionId);
    }
  }

  /// A throwing listener must not keep the others from hearing about the session.
  static void _notifySessionListener(void Function(String sessionId) listener, String sessionId) {
    try {
      listener(sessionId);
    } catch (error, stack) {
      presentAppError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'coryn_replay',
          context: ErrorDescription('in an onRecordingStarted listener'),
          silent: kReleaseMode,
        ),
      );
    }
  }

  /// The native recorder stopped, possibly not on Dart's request (critical error, remote disablement). A native stop
  /// is final for the process (one recorder per process), so this isolate stops for good as after `stopRecording`:
  /// providers are removed (and notified) and later registrations are refused.
  @override
  void onRecordingStopped() {
    _sessionId = null;
    _sessionListeners.clear();
    onStopRequested();
  }

  @override
  Future<bool> sendStateBatch(Uint8List batch) async {
    final isAttached = await ensureAttached();
    return isAttached && await platform.sendStateBatch(batch);
  }
}
