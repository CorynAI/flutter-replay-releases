/// When the Log Viewer indicator is shown (needs the native `ai.coryn.replay.api:log-viewer` artifact).
/// Mirrors the Android `CorynLogViewerIndicatorVisibility`.
enum CorynLogViewerIndicatorVisibility {
  /// Always visible.
  visibleAlways('VISIBLE_ALWAYS'),

  /// Visible when any SDK configuration error was encountered (orange or red).
  visibleIfAnyErrors('VISIBLE_IF_ANY_ERRORS'),

  /// Visible only for errors that cancel recording (red).
  visibleIfRecordingCriticalErrors('VISIBLE_IF_RECORDING_CRITICAL_ERRORS'),

  /// Never visible.
  gone('GONE');

  const CorynLogViewerIndicatorVisibility(this.nativeName);

  /// Name of the Android enum constant.
  final String nativeName;
}

/// SDK configuration passed to `Coryn.init`. Mirrors the Android `CorynConfiguration.Builder`.
///
/// The first `init` call in a process wins, including a native `Coryn.init` from `Application.onCreate`.
final class CorynConfiguration {
  const CorynConfiguration({
    this.networkBaseUrl,
    this.isUploadOnMeteredNetworkAllowed,
    this.isPreEraseEnabled,
    this.logViewerIndicatorVisibility,
    this.logViewerIndicatorPaddingTop,
    this.logViewerIndicatorPaddingRight,
  });

  /// Base API URL for self-hosted deployments. Leave `null` for the Coryn cloud.
  final String? networkBaseUrl;

  /// Whether recordings may upload on metered networks. `null` keeps the SDK default.
  final bool? isUploadOnMeteredNetworkAllowed;

  /// Whether stored recordings are erased before initialisation. `null` keeps the SDK default.
  final bool? isPreEraseEnabled;

  final CorynLogViewerIndicatorVisibility? logViewerIndicatorVisibility;

  /// Extra top padding of the Log Viewer indicator, in dp.
  final int? logViewerIndicatorPaddingTop;

  /// Extra right padding of the Log Viewer indicator, in dp.
  final int? logViewerIndicatorPaddingRight;

  Map<String, Object?> toMap() => <String, Object?>{
    'networkBaseUrl': networkBaseUrl,
    'isUploadOnMeteredNetworkAllowed': isUploadOnMeteredNetworkAllowed,
    'isPreEraseEnabled': isPreEraseEnabled,
    'logViewerIndicatorVisibility': logViewerIndicatorVisibility?.nativeName,
    'logViewerIndicatorPaddingTop': logViewerIndicatorPaddingTop,
    'logViewerIndicatorPaddingRight': logViewerIndicatorPaddingRight,
  };
}

/// Recording configuration passed to `Coryn.startRecording`. Mirrors the Android `CorynRecordingConfiguration`.
final class CorynRecordingConfiguration {
  const CorynRecordingConfiguration({this.isUiCapturingEnabled, this.memoryLeakCodePackages = const <String>{}});

  /// Whether UI captures are recorded. `null` keeps the SDK default (enabled unless disabled remotely).
  final bool? isUiCapturingEnabled;

  /// Kotlin/Java packages whose objects count as app code for native memory-leak reports.
  final Set<String> memoryLeakCodePackages;

  Map<String, Object?> toMap() => <String, Object?>{
    'isUiCapturingEnabled': isUiCapturingEnabled,
    'memoryLeakCodePackages': memoryLeakCodePackages.toList(),
  };
}

/// Dart-side capture options. They change how Flutter frames are captured and masked.
final class CorynCaptureOptions {
  const CorynCaptureOptions({
    this.maskObscuredText = true,
    this.minCaptureInterval = const Duration(milliseconds: 200),
  });

  /// Masks every text field with `obscureText` even without `CorynHide`, by masking its nearest repaint boundary.
  /// Defaults to `true`.
  final bool maskObscuredText;

  /// Shortest time between two captures while the UI keeps changing (the native capture rate is "as fast as the
  /// pipeline allows"). Larger values lower the cost during animations. Defaults to 200 ms.
  final Duration minCaptureInterval;
}
