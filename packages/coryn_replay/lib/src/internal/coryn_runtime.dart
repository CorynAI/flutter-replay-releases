import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../capture/coryn_capture_scheduler.dart';
import '../platform/coryn_platform.dart';
import '../platform/method_channel_coryn_platform.dart';
import '../platform/noop_coryn_platform.dart';
import '../screens/coryn_screen_registration.dart';
import '../state/coryn_state_sampler.dart';

/// Wires the platform bridge, state sampler and capture scheduler of the root isolate.
final class CorynRuntime with WidgetsBindingObserver implements CorynPlatformListener, CorynStateBatchSink {
  CorynRuntime._(this.platform) {
    sampler = CorynStateSampler(this);
    capture = CorynCaptureScheduler(platform);
  }

  static CorynRuntime? _instance;

  /// The runtime of this isolate.
  static CorynRuntime get instance => _instance ??= CorynRuntime._(_defaultPlatform());

  /// Replaces the runtime for tests.
  @visibleForTesting
  static void debugReset(CorynPlatform platform) {
    _instance?._dispose();
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
  final List<void Function(String sessionId)> _sessionListeners = <void Function(String sessionId)>[];
  Future<bool>? _attached;
  String? _sessionId;
  bool _isRecordingStopped = false;

  /// Id of the native session, once it started.
  String? get sessionId => _sessionId;

  /// Attaches to the native plugin once per isolate and completes with whether native calls can be made. Safe to call
  /// repeatedly.
  Future<bool> ensureAttached() => _attached ??= _attach();

  Future<bool> _attach() async {
    if (!platform.isSupported) return false;
    final binding = WidgetsFlutterBinding.ensureInitialized();
    binding.addObserver(this);
    SchedulerBinding.instance.addPersistentFrameCallback((_) => capture.onFrame());
    _applyLifecycle(binding.lifecycleState);
    final CorynNativeStatus status;
    try {
      status = await platform.attach(this);
    } on MissingPluginException catch (error) {
      // An engine without registered plugins (custom add-to-app engine, a plain unit test): record nothing.
      logFailureOnce('attach', error);
      return false;
    }
    if (status.isRecordingStopped) {
      onRecordingStopped();
      return true;
    }
    capture.geometryRevision = status.geometryRevision;
    final targetFps = status.captureTargetFps;
    if (targetFps != null && !_isRecordingStopped) capture.start(targetFps);
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
  /// reach `CorynErrorReporter`, which records it with another call). Debug builds print the first failure per call.
  void logFailureOnce(String call, Object error) {
    if (kReleaseMode || !_loggedFailures.add(call)) return;
    debugPrint('Coryn: $call failed: $error');
  }

  void _dispose() {
    capture.stop();
    sampler.clear();
    if (_attached != null) WidgetsBinding.instance.removeObserver(this);
  }

  /// Calls [listener] once the native session started (immediately when it already has).
  void addSessionListener(void Function(String sessionId) listener) {
    final sessionId = _sessionId;
    if (sessionId != null) {
      _notifySessionListener(listener, sessionId);
      return;
    }
    _sessionListeners.add(listener);
  }

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

  void _applyLifecycle(AppLifecycleState? state) {
    final isPaused = switch (state) {
      AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => true,
      AppLifecycleState.resumed || AppLifecycleState.inactive || null => false,
    };
    sampler.isPaused = isPaused;
    capture.isPaused = isPaused;
  }

  @override
  void onCaptureStart(double targetFps) {
    if (_isRecordingStopped) return;
    capture.start(targetFps);
  }

  @override
  void onCaptureStop() => capture.stop();

  @override
  void onCaptureInvalidate(int geometryRevision) => capture.invalidate(geometryRevision);

  @override
  void onCaptureReady() => capture.onNativeReady();

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
      FlutterError.reportError(
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
