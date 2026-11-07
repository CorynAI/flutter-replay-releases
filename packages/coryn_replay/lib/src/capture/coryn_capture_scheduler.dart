import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../configuration.dart';
import '../platform/coryn_platform.dart';
import 'coryn_capture_stats.dart';
import 'coryn_frame_message.dart';
import 'coryn_hidden_layers.dart';
import 'coryn_root.dart';
import 'coryn_scene_masker.dart';

/// Produces masked UI captures of the attached [RenderCorynRoot].
///
/// Captures are taken only in a persistent frame callback, right after the frame was composited and before post-frame
/// callbacks, timers and channel messages can change the state that decides masking while the layer tree still holds
/// the old pixels. Code that runs earlier in the frame (persistent callbacks registered before Coryn's, disposals) may
/// still change it: hide and obscured-text flags can then only make the capture show what the app is about to show,
/// and snapshot images are recognised from the painted layer tree (`collectHiddenLayers`), not from their controller.
///
/// Nothing is captured before the engine rasterized its first frame: Impeller's OpenGL ES backend can fault on an image
/// snapshot taken that early (a new engine attaching to a running capture after an in-process relaunch).
///
/// Pacing mirrors the native capture loop, whose target rate is effectively "as fast as the pipeline allows":
/// * A capture happens only when a frame was produced since the last *accepted* capture (or native asked for one),
///   when native is ready (it signals readiness after compressing the previous frame and the encoder's pause), and at
///   most once per [CorynCaptureOptions.minCaptureInterval]. Busy, rejected and failed captures keep the frame dirty.
///   When a capture is due and no frame is coming (native asked, a ready signal arrived after the last frame, the last
///   change came inside the interval), the scheduler asks for a frame.
/// * Between captures (nothing changed, a change waiting for the interval, the app paused) a cheap "unchanged" health
///   message goes out every [healthInterval]: native treats the UI as healthy only if it hears from the producer within
///   about 1.5 s, also in the background, and answers whether its last frame was recorded. The message vouches for the
///   last capture, so it is sent only while that capture was accepted (also while native compresses it or cools down
///   the encoder, when native itself decides); after a busy, rejected or failed capture native health lapses until a
///   capture is accepted. Nothing vouches before the first capture of a recording, so native gives that one 4 s.
final class CorynCaptureScheduler {
  CorynCaptureScheduler(this._platform);

  /// Native captures fit the screen into 768 x 1024 (`CorynUICaptureConstants`).
  static const double targetWidth = 768;
  static const double targetHeight = 1024;

  final CorynPlatform _platform;
  final CorynCaptureStats stats = CorynCaptureStats();
  final Stopwatch _clock = Stopwatch()..start();

  /// Current time for pacing; tests replace it.
  @visibleForTesting
  late Duration Function() now = () => _clock.elapsed;

  /// Whether the engine rasterized its first frame; tests replace it (the test binding never rasterizes).
  @visibleForTesting
  bool Function() isFirstFrameRasterized = () => WidgetsBinding.instance.firstFrameRasterized;
  CorynCaptureOptions options = const CorynCaptureOptions();

  /// Interval of "unchanged" health messages; native expects one within 1.5 s.
  @visibleForTesting
  Duration healthInterval = const Duration(milliseconds: 500);

  /// The periodic timer only sends health messages and asks for trailing frames, so it never runs faster than this.
  static const Duration minTimerInterval = Duration(milliseconds: 100);

  RenderCorynRoot? _root;
  Timer? _timer;
  double? _targetFps;
  int _frameCount = 0;
  int _capturedFrame = -1;
  bool _needsCapture = true;
  bool _isNativeReady = true;
  bool _isLastCaptureAccepted = false;

  /// Counts native ready signals; a signal that arrives while a submission is in flight belongs to that frame.
  int _readySignals = 0;

  /// Changes on every start/stop, so completions of a previous capture run are ignored.
  int _runId = 0;

  /// Native view geometry revision; after it changes, only a frame produced afterwards may be captured.
  int _geometryRevision = 0;
  int? _invalidatedAtFrame;
  bool _isInFlight = false;
  bool _isPaused = false;
  bool _isFailureReported = false;
  Duration? _lastCaptureAt;
  Duration? _lastHealthAt;

  /// Whether native currently asks for captures.
  bool get isCapturing => _targetFps != null;

  /// The outermost root is captured: a `CorynRoot` nested in the captured one (for example in a page or package) is
  /// ignored, so it neither crops the capture nor stops it when it leaves.
  void attachRoot(RenderCorynRoot root) {
    final current = _root;
    final isNested = current != null && current.attached && _isAncestor(current, root);
    if (isNested) return;
    _root = root;
    _needsCapture = true;
  }

  static bool _isAncestor(RenderObject ancestor, RenderObject node) {
    for (RenderObject? parent = node.parent; parent != null; parent = parent.parent) {
      if (identical(parent, ancestor)) return true;
    }
    return false;
  }

  void detachRoot(RenderCorynRoot root) {
    if (identical(_root, root)) _root = null;
  }

  /// Counts produced frames and captures the frame when due. Called from a persistent frame callback after the frame
  /// was composited; the capture's synchronous part (masking, scene, rasterization request) runs right here.
  void onFrame() {
    _frameCount++;
    final root = _root;
    if (root == null || !_isCaptureDue(root)) return;
    _invalidatedAtFrame = null;
    unawaited(_captureFrame(root, now()));
  }

  /// Whether the last composited frame may be captured now.
  bool _isCaptureDue(RenderCorynRoot root) {
    if (_isInFlight || _isPaused || _targetFps == null || !_isNativeReady) return false;
    if (!root.attached || !root.hasSize || !isFirstFrameRasterized()) return false;
    final isDirty = _needsCapture || _frameCount != _capturedFrame;
    if (!isDirty) return false;
    final lastCaptureAt = _lastCaptureAt;
    final isThrottled = lastCaptureAt != null && now() - lastCaptureAt < options.minCaptureInterval;
    final invalidatedAtFrame = _invalidatedAtFrame;
    final isAwaitingFrame = invalidatedAtFrame != null && _frameCount <= invalidatedAtFrame;
    return !isThrottled && !isAwaitingFrame;
  }

  /// A capture is due but happens only in a frame: ask for one (nothing if a frame is already scheduled).
  void _requestFrameIfDue() {
    final root = _root;
    if (root != null && _isCaptureDue(root)) SchedulerBinding.instance.scheduleFrame();
  }

  /// Captures follow [CorynCaptureOptions.minCaptureInterval] at event time; the periodic timer runs at that interval
  /// for trailing frames, but at least every [healthInterval] and at most every [minTimerInterval]. Native also calls
  /// start to change the rate of a running capture (feature flags refreshed); pacing does not depend on the rate, so
  /// such a call keeps the run, its in-flight capture and what native already recorded.
  void start(double targetFps) {
    final isRunning = _targetFps != null;
    _targetFps = targetFps;
    if (isRunning) return;
    _runId++;
    _needsCapture = true;
    _isNativeReady = true;
    _isLastCaptureAccepted = false;
    var interval = options.minCaptureInterval;
    if (interval > healthInterval) interval = healthInterval;
    if (interval < minTimerInterval) interval = minTimerInterval;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => tick());
    scheduleMicrotask(tick);
  }

  void stop() {
    _runId++;
    _targetFps = null;
    _timer?.cancel();
    _timer = null;
  }

  /// Native geometry changed: frames captured for the old geometry are rejected, so wait for (and request) a new frame.
  void invalidate(int geometryRevision) {
    _geometryRevision = geometryRevision;
    _needsCapture = true;
    _invalidatedAtFrame = _frameCount;
    SchedulerBinding.instance.scheduleFrame();
  }

  /// Geometry revision reported by attach.
  set geometryRevision(int value) => _geometryRevision = value;

  /// Native finished the previous frame.
  void onNativeReady() {
    _readySignals++;
    _isNativeReady = true;
    _requestFrameIfDue();
  }

  set isPaused(bool value) {
    _isPaused = value;
    if (!value) _needsCapture = true;
  }

  /// Periodic tick: asks for a frame when a capture is due (it is taken in that frame), otherwise sends a health
  /// message while the last capture was accepted, also while the app is paused (native's own capture reports "no
  /// views" in the background). Public for tests and benchmarks.
  Future<void> tick() async {
    if (_isInFlight || _targetFps == null) return;
    final root = _root;
    if (root == null || !root.attached || !root.hasSize) return;
    if (_isCaptureDue(root)) {
      SchedulerBinding.instance.scheduleFrame();
      return;
    }
    if (!_isLastCaptureAccepted) return;
    final time = now();
    final lastHealthAt = _lastHealthAt;
    final isHealthDue = lastHealthAt == null || time - lastHealthAt >= healthInterval;
    if (isHealthDue) await _reportUnchanged(time);
  }

  /// Readiness is consumed before submitting. Native may signal ready (on another channel) before the frame reply
  /// arrives; such a signal means this frame is already done, so it is kept.
  Future<void> _captureFrame(RenderCorynRoot root, Duration now) async {
    _isInFlight = true;
    _lastCaptureAt = now;
    _lastHealthAt = now;
    final runId = _runId;
    final readySignalsBefore = _readySignals;
    _isNativeReady = false;
    try {
      final frame = _frameCount;
      final CorynFrameResult? result;
      try {
        result = await _capture(root);
      } catch (error, stack) {
        if (runId != _runId) return;
        _needsCapture = true;
        _isNativeReady = true;
        _isLastCaptureAccepted = false;
        stats.rejectedCaptures++;
        _reportFailureOnce('capture failed: $error', stack);
        return;
      }
      if (runId != _runId) return;
      final wasReadySignalled = _readySignals != readySignalsBefore;
      _isLastCaptureAccepted = result == CorynFrameResult.accepted;
      switch (result) {
        case CorynFrameResult.accepted:
          _capturedFrame = frame;
          _needsCapture = false;
          _isNativeReady = wasReadySignalled;
        case CorynFrameResult.busy:
          _needsCapture = true;
          _isNativeReady = wasReadySignalled;
        case CorynFrameResult.rejected || null:
          _needsCapture = true;
          _isNativeReady = true;
      }
    } finally {
      _isInFlight = false;
    }
  }

  /// Until native signals ready, the accepted frame may still be compressing (native answers "not recorded" then) or
  /// already recorded and cooling down the encoder; only an answer given while native is ready asks for a new capture.
  Future<void> _reportUnchanged(Duration now) async {
    _isInFlight = true;
    _lastHealthAt = now;
    final wasNativeReady = _isNativeReady;
    try {
      final isRecorded = await _platform.sendUiUnchanged();
      stats.unchangedTicks++;
      if (!isRecorded && wasNativeReady) _needsCapture = true;
    } finally {
      _isInFlight = false;
    }
  }

  Future<CorynFrameResult?> _capture(RenderCorynRoot root) async {
    final total = Stopwatch()..start();
    // The image belongs to the geometry of this moment; it is dropped if the geometry changes before it is sent.
    final geometryRevision = _geometryRevision;
    final view = root.flutterView;
    final devicePixelRatio = view.devicePixelRatio;
    final pixelRatio = devicePixelRatio / _scaleFactor(view);
    final size = root.size;
    final imageWidth = math.max(1, (size.width * pixelRatio).round());
    final imageHeight = math.max(1, (size.height * pixelRatio).round());
    final rootOffset = root.localToGlobal(Offset.zero) * devicePixelRatio;
    final viewSize = view.physicalSize;

    final walk = Stopwatch()..start();
    final hidden = collectHiddenLayers(root, options);
    final masked = CorynSceneMasker(hidden).build(root.captureLayer, pixelRatio, imageWidth, imageHeight);
    walk.stop();
    switch (masked) {
      case CorynMaskedSceneNotPainted():
        return null;
      case CorynMaskedSceneRejected(:final reason):
        stats.rejectedCaptures++;
        _reportFailureOnce(reason);
        return null;
      case CorynMaskedImage():
        break;
    }
    final image = masked.image;
    final readback = Stopwatch()..start();
    final ByteData? pixels;
    try {
      pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      image.dispose();
    }
    readback.stop();
    if (pixels == null) {
      stats.rejectedCaptures++;
      return null;
    }
    final isGeometryChanged = geometryRevision != _geometryRevision;
    if (isGeometryChanged) return null;
    final encode = Stopwatch()..start();
    final header = CorynFrameMessage.header(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      rootLeft: rootOffset.dx.round(),
      rootTop: rootOffset.dy.round(),
      rootWidth: (size.width * devicePixelRatio).round(),
      rootHeight: (size.height * devicePixelRatio).round(),
      viewWidth: viewSize.width.round(),
      viewHeight: viewSize.height.round(),
      timePassedMs: total.elapsedMilliseconds,
      geometryRevision: geometryRevision,
    );
    encode.stop();
    final send = Stopwatch()..start();
    final result = await _platform.sendFrame(header, pixels);
    send.stop();
    total.stop();
    stats.record(
      result: result,
      hiddenLayers: hidden.length,
      bytes: header.length + pixels.lengthInBytes,
      walk: walk.elapsed,
      readback: readback.elapsed,
      encode: encode.elapsed,
      send: send.elapsed,
      total: total.elapsed,
    );
    return result;
  }

  /// Same fit as native captures: the display is scaled down to fit 768 x 1024.
  static double _scaleFactor(ui.FlutterView view) {
    final displaySize = view.display.size;
    final hasDisplaySize = displaySize.width > 0 && displaySize.height > 0;
    final size = hasDisplaySize ? displaySize : view.physicalSize;
    return math.max(1, math.max(size.width / targetWidth, size.height / targetHeight));
  }

  void _reportFailureOnce(String reason, [StackTrace? stack]) {
    if (_isFailureReported) return;
    _isFailureReported = true;
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('Coryn UI capture rejected: $reason'),
        stack: stack,
        library: 'coryn_replay',
        context: ErrorDescription('while capturing a Coryn UI frame'),
        silent: kReleaseMode,
      ),
    );
  }
}
