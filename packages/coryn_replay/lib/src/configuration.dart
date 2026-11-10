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
    this.includeErrorMessages = false,
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

  /// Whether recorded uncaught Dart errors include their message (truncated), which can contain user data. Defaults to
  /// `false`. Dart-side: the first Dart `Coryn.init` of the engine decides it, even after a native `Coryn.init`.
  final bool includeErrorMessages;

  Map<String, Object?> toMap() => <String, Object?>{
    'networkBaseUrl': networkBaseUrl,
    'isUploadOnMeteredNetworkAllowed': isUploadOnMeteredNetworkAllowed,
    'isPreEraseEnabled': isPreEraseEnabled,
    'logViewerIndicatorVisibility': logViewerIndicatorVisibility?.nativeName,
    'logViewerIndicatorPaddingTop': logViewerIndicatorPaddingTop,
    'logViewerIndicatorPaddingRight': logViewerIndicatorPaddingRight,
  };
}

/// What a recording captures from the UI. Mirrors the Android `CorynUiCapturing`.
///
/// Content inside `CorynHide` is left out of both screen text and visuals. The backend can only lower it: when UI
/// capturing is disabled remotely, neither text nor visuals are captured. Touches are recorded only with visuals.
enum CorynUiCapturing {
  /// Nothing is captured from the UI: no screen text, no visuals and no touches.
  disabled('DISABLED'),

  /// Only the text visible on screen is captured.
  onlyText('ONLY_TEXT'),

  /// The text visible on screen, UI captures (visuals) and touches are captured.
  textAndVisuals('TEXT_AND_VISUALS');

  const CorynUiCapturing(this.nativeName);

  /// Name of the Android enum constant.
  final String nativeName;
}

/// Recording configuration passed to `Coryn.startRecording`. Mirrors the Android `CorynRecordingConfiguration`.
final class CorynRecordingConfiguration {
  const CorynRecordingConfiguration({this.uiCapturing, this.memoryLeakCodePackages = const <String>{}});

  /// What is captured from the UI. `null` keeps the SDK default, [CorynUiCapturing.disabled]: hide private content with
  /// `CorynHide` before enabling it.
  final CorynUiCapturing? uiCapturing;

  /// Kotlin/Java packages whose objects count as app code for native memory-leak reports.
  final Set<String> memoryLeakCodePackages;

  Map<String, Object?> toMap() => <String, Object?>{
    'uiCapturing': uiCapturing?.nativeName,
    'memoryLeakCodePackages': memoryLeakCodePackages.toList(),
  };
}

/// Dart-side capture options. They change how Flutter frames are masked; the capture rate comes from the backend.
final class CorynCaptureOptions {
  const CorynCaptureOptions({this.maskObscuredText = true});

  /// Masks every text field with `obscureText` even without `CorynHide`, by masking its nearest repaint boundary.
  /// Defaults to `true`.
  final bool maskObscuredText;
}
