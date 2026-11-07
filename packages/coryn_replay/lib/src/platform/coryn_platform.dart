import 'dart:typed_data';

import '../configuration.dart';
import '../network/coryn_api_request.dart';

/// Result of a frame submission, mirroring the Android `CorynExternalUiCaptureResult`.
enum CorynFrameResult {
  /// The frame was copied and will be recorded.
  accepted,

  /// The previous frame is still being compressed; the frame was dropped.
  busy,

  /// The frame was dropped (capturing stopped, app not visible, or native preparation failed).
  rejected,
}

/// Callbacks from the native SDK.
abstract interface class CorynPlatformListener {
  /// UI capturing started or changed its target rate.
  void onCaptureStart(double targetFps);

  /// UI capturing stopped.
  void onCaptureStop();

  /// The native view moved, resized, or changed display or Activity ([geometryRevision] is its new revision). Frames
  /// captured before the next Flutter frame are rejected.
  void onCaptureInvalidate(int geometryRevision);

  /// Native finished the previous frame and accepts the next one.
  void onCaptureReady();

  /// A recording session started. Forwarded to `onRecordingStarted` passed to `Coryn.startRecording`.
  void onRecordingStarted(String sessionId);

  /// The native recorder stopped (stop request, cancellation, remote disablement); another session may start later.
  void onRecordingStopped();
}

/// Native status returned by [CorynPlatform.attach].
final class CorynNativeStatus {
  const CorynNativeStatus({
    this.captureTargetFps,
    this.sessionId,
    this.geometryRevision = 0,
    this.isRecordingStopped = false,
  });

  /// Target capture rate when the native SDK is capturing UI now, otherwise `null`.
  final double? captureTargetFps;

  /// Id of the session that is recording now, if any.
  final String? sessionId;

  /// Revision of the native view geometry; frames carry the revision they were captured for.
  final int geometryRevision;

  /// The native recorder stopped (a stop is final for the process), for example before this isolate or engine existed.
  final bool isRecordingStopped;
}

/// Native bridge used by the Dart SDK. Android talks to the Coryn Android SDK; other platforms use a no-op.
abstract interface class CorynPlatform {
  /// Whether this platform records anything. `false` for the no-op implementation.
  bool get isSupported;

  /// Connects [listener], resets native state left by a previous Dart isolate (hot restart) and returns the current
  /// native status.
  Future<CorynNativeStatus> attach(CorynPlatformListener listener);

  Future<void> init(String apiKey, CorynConfiguration? configuration);

  Future<void> startRecording(String? delayReason, CorynRecordingConfiguration? configuration);

  Future<void> stopRecording(String? reason);

  /// Registers a manual-scope screen and returns its handle for [unregisterScreen].
  Future<int> registerScreen(String name, Map<String, Object>? arguments);

  Future<void> unregisterScreen(int handle);

  Future<void> addEvent(String eventId, String? stateJson, int timePassedMs);

  Future<void> addApiRequest(CorynApiRequest request);

  Future<void> showToast(String text, bool isLong);

  /// Sends one binary state batch and completes with `true` once native applied it.
  Future<bool> sendStateBatch(Uint8List batch);

  /// Sends a frame header and its RGBA [pixels] (as two consecutive messages) and completes with the native result.
  Future<CorynFrameResult> sendFrame(Uint8List header, ByteData pixels);

  /// Reports a capture tick without UI change. Completes with `false` when native did not record the last frame and
  /// a new frame must be captured.
  Future<bool> sendUiUnchanged();

  /// Native counters for tests and benchmarks.
  Future<Map<String, Object?>> debugStats();
}
