## 0.2.0

* Requires Coryn Android SDK 1.1.134; all native Coryn modules must resolve to the same version.
* Breaking: `CorynRecordingConfiguration.isUiCapturingEnabled` is replaced by `uiCapturing` with
  `CorynUiCapturing.disabled` (the new default), `onlyText` and `textAndVisuals`. Hide private content with `CorynHide`
  before enabling screen text or visuals.
* Visible Flutter screen text is recorded in text-only and text-and-visuals modes, excluding hidden, obscured, clipped,
  ellipsized, transparent, filtered or blended text. It is read only while the `FlutterView` renders into its default
  surface view and is fully on screen; texture-mode views and hybrid platform views record no screen text.
* Flutter touches are recorded with visuals. Touches in `CorynHide` are suppressed unless `allowTouchRecording: true`;
  initialise Coryn before `runApp` so touch privacy covers every submitted frame.
* `Coryn.setUserId` associates recordings with an internal account ID; pass `null` on sign-out. Device retention is
  enforced by the native SDK using the backend TTL (7 days by default).
* Breaking: `CorynCaptureOptions.minCaptureInterval` is removed. The UI capture rate comes only from the backend
  (`capturingFps` in the project's feature flags), which the native SDK passes to Dart, also when refreshed flags
  change it during a recording. Native readiness also limits the rate.
* Privacy: the selection handles and toolbar of an obscured text field, or of a field inside a hidden `CorynHide`, are
  no longer recorded. They are drawn in the Overlay where the text ends, so they revealed the text's length. While
  such a field is on screen, a selection magnifier masks its whole Overlay (usually the whole screen) for the same
  reason.
* Breaking: screens carry `isDialog`. `Coryn.registerScreen(name, isDialog: ...)` and `CorynScreen(isDialog: ...)`
  require it. The pinned Android SDK records the flag in the screen state.
* `CorynNavigatorObserver` records named dialogs and sheets (`PopupRoute`) as screens of their own, with
  `isDialog: true`, as the Android SDK does. The page and named popups below stay registered under them, so closing
  one returns to the screen the user sees again, also a nested Navigator's page or a `CorynScreen` inside the screen
  below. Unnamed popup routes
  still leave the page below as the screen.
* Breaking: `Coryn.init` records uncaught Dart errors itself; `CorynErrorReporter` is removed. Use
  `CorynConfiguration(includeErrorMessages: true)` instead of `CorynErrorReporter.install(includeMessages: true)`.
* App callback failures that Coryn catches and presents (state providers, session listeners, HTTP transforms and
  conversions) are no longer recorded as `FlutterError` events, and an app that set `FlutterError.onError` to `null`
  stays silent after `Coryn.init`.
* At most 10 uncaught Dart errors are recorded in each one-second window, so an error repeated every frame stays
  cheap; every error still reaches the previous handlers.

## 0.1.0

* First release: Android session recording through the Coryn Android SDK, with UI capture masking (`CorynHide`),
  screens, states, events, API requests, toasts and uncaught Dart errors. Other platforms are no-ops.
