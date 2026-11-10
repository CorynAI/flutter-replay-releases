# coryn_replay

Coryn Session Replay SDK for Flutter. Android records sessions through the native Coryn Android SDK; on iOS, web and
desktop every call is a no-op and the widgets only render their child.

Network integrations: [`coryn_replay_http`](../coryn_replay_http) for `package:http` and
[`coryn_replay_dio`](../coryn_replay_dio) for Dio.

## Quick start

Install it from the [releases repository](https://github.com/CorynAI/flutter-replay-releases) at a release tag:

```yaml
dependencies:
  coryn_replay:
    git:
      url: https://github.com/CorynAI/flutter-replay-releases.git
      path: packages/coryn_replay
      ref: v0.2.0
```

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // After other error reporters (Crashlytics, Sentry): init chains the error handlers set before it.
  await Coryn.init('YOUR_CORYN_API_KEY');
  await Coryn.startRecording(
    // UI capturing is disabled by default: hide private content with CorynHide first, then enable it.
    configuration: const CorynRecordingConfiguration(uiCapturing: CorynUiCapturing.textAndVisuals),
    onRecordingStarted: (sessionId) => analytics.setSessionId(sessionId),
  );
  runApp(const CorynRoot(child: MyApp()));
}
```

The plugin's Android code and the Coryn Android SDK come from the Coryn Maven repository, which the app declares
where it declares its other repositories. In a Flutter app that is `android/build.gradle.kts`:

```kotlin
// android/build.gradle.kts
allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://nexus.witrix.ai/repository/android-public") }
    }
}
```

A host app that declares repositories in `settings.gradle.kts` (`dependencyResolutionManagement`, for example with
add-to-app) adds the same `maven { ... }` line there; the plugin declares no repositories of its own.

`minSdk` must be 26 or higher and `compileSdk` 36 or higher (Flutter's default).

Coryn supports Android release builds with Flutter's `--obfuscate` and `--split-debug-info` and with R8, using the
bundled consumer rules; recorded diagnostic type names and Dart stack traces may be obfuscated, so keep the matching
symbol files and, if needed, an obfuscation name map.

Call `Coryn.init` on every app start, before `runApp`, whatever the user's consent: it does not start a replay session
(it can still store SDK diagnostics and upload data stored by earlier launches).
Initialisation and recording are separate on purpose, so gate `Coryn.startRecording` (with a `delayReason` such as
`'Waiting for user consent'`) on consent, never `init`. Until `init` succeeds, events, API requests and toasts are
dropped silently, HTTP integrations record nothing, state providers are kept and sampled only once a session records, and
the screens registered meanwhile (`CorynNavigatorObserver`, `CorynScreen`) are registered once `init` succeeds. Awaited calls (`startRecording`,
`stopRecording`) still report native errors. Keep one `CorynNavigatorObserver` per Navigator for the Navigator's lifetime (a field,
not created in `build`), and call its `dispose()` when a nested Navigator goes away while the app keeps running.

Call `Coryn.init` before `runApp` also for touches: Flutter touches are recorded only when the SDK has seen every frame
of the screen surface, so a later `init` records no Flutter touches until the app goes to the background and back.

### UI capturing, user ID and retention

`CorynRecordingConfiguration.uiCapturing` selects what is captured from the UI. It defaults to
`CorynUiCapturing.disabled`; `onlyText` records the visible screen text, `textAndVisuals` records the visible text, UI
captures and touches. The backend can only lower it. Hide private content with `CorynHide` before enabling it.

`Coryn.setUserId(accountId)` tags recordings with your user's ID, so that one person's recordings can be found and
erased on request; pass `null` on sign-out. Use an internal account ID, never an email, phone number or name. A
recording lists the ID set when it started and every other distinct ID set during it; more than 10 distinct IDs in one
recording cancel it.

Sessions that were not uploaded are deleted from the device after the retention period (`ttl` from the backend, 7 days
by default).

Only the root (UI) isolate records. In other isolates (`compute`, `Isolate.run`) every Coryn call is a no-op,
`Coryn.isRecording` is `false`, and `CorynHttpClient` / `CorynDioInterceptor` pass requests through unrecorded.

## API

| Android (`Coryn.kt`) | Flutter |
|---|---|
| `Coryn.init(application, apiKey, configuration)` | `Coryn.init(apiKey, configuration: CorynConfiguration(...), captureOptions: ...)` |
| `Coryn.startRecording(delayReason, configuration)` + `CorynRecordingListener` | `Coryn.startRecording(delayReason:, configuration:, onRecordingStarted:)` |
| `Coryn.stopRecording(reason)` | `Coryn.stopRecording(reason)` |
| `registerScreen` / `registerManualScopeScreen` | `CorynNavigatorObserver`, `CorynScreen(name:, isDialog:)`, `Coryn.registerScreen(name, isDialog:)` |
| `provide` / `provideManualScopeStateProvider` | `CorynStateScope`, `Coryn.provideState(id, provider)` / `removeState(id, provider:)` |
| `removeManualScopeStateProvider(id, expectedProvider)` | `Coryn.removeState(id, provider: p)` removes only while `p` is registered |
| — (recording state) | `Coryn.isRecording`, `Coryn.sessionId` |
| `CorynStateProvider` / `CorynState` | `CorynStateProvider` / `CorynState` (+ `CorynJsonState`, `CorynValueListenableStateProvider`) |
| `addEvent(eventId, state, timePassedMs)` | `Coryn.addEvent(id, state:, timePassed:)` |
| `addApiRequest(...)`, OkHttp interceptor | `Coryn.addApiRequest(CorynApiRequest(...))`, `CorynHttpClient`, `CorynDioInterceptor` |
| `hideFromUiCapture(view, allowTouchRecording)`, `Modifier.corynHideFromUiCapture()` | `CorynHide(child:, padding:, allowTouchRecording:)` |
| `setUserId(userId)` | `Coryn.setUserId(userId)` |
| `CorynRecordingConfiguration.Builder().setUiCapturing(...)` | `CorynRecordingConfiguration(uiCapturing: CorynUiCapturing...)` |
| `acceptToast(...)` | `Coryn.showToast(text)` |
| — (native crashes) | `Coryn.init` also records uncaught Dart errors (`CorynConfiguration.includeErrorMessages` adds messages) |

### Hiding content

```dart
CorynHide(padding: EdgeInsets.all(4), child: Text(cardNumber))
```

Captures rebuild the last frame with every hidden subtree replaced by a black box *before* blur, magnifiers, image
filters, shaders or opacity apply, so no effect can reveal or move hidden pixels; everything the subtree paints is
removed, including overflow. Text fields with `obscureText` are masked automatically (their nearest repaint boundary;
wrap them in `CorynHide` for a tight mask). Platform views and textures (WebView, maps, video, camera) are always black.

What a hidden subtree shows in the Overlay through an `OverlayPortal` (tooltips, `MenuAnchor` and `DropdownMenu` menus,
`Autocomplete` options) is masked too, at the Overlay's nearest repaint boundary: usually the whole screen is black
while it is shown. Hide content that widgets outside the hidden subtree draw yourself: put `CorynHide` inside a `Hero`,
and hide routes (dialogs, `DropdownButton` menus), overlay entries or custom painters that show the same data.

Screen text never contains text below an enabled `CorynHide` or of an `obscureText` field. Only text shown in full is
read: ellipsized, scrolled, clipped, transparent, filtered or blended text is left out. Screen text is read only while
the `FlutterView` renders into its default surface view and is fully on screen without native transforms, layers,
animations or clips: a texture-mode `FlutterView` or one showing hybrid-composition platform views records no screen
text.

Touches inside a `CorynHide` (including its padding) are not recorded unless `allowTouchRecording: true`: a touch that
starts in or moves into it is not recorded from then until it ends, so typing on a custom PIN pad cannot be
reconstructed. Because the screen can still show an older frame than the one Flutter built, an area where such a hide
was shown stays without touch recording until the screen surface is replaced (the app goes to the background).

Snapshots (`SnapshotWidget`, used by `ZoomPageTransitionsBuilder` while a transition runs) draw a cached image that can
still hold content hidden or removed since, so a snapshot is recorded black unless it provably paints its child live.
Zoom page transitions are therefore black in replays while they run (about 300 ms); the default Android transition
does not use snapshots. A `SnapshotWidget` of your own stays black unless its child contains a `RepaintBoundary`.

### States

```dart
final class CartState implements CorynState {
  const CartState(this.items);
  final List<String> items;
  @override
  Object? toJson() => {'items': items};
  @override
  bool operator ==(Object other) => other is CartState && listEquals(other.items, items);
  @override
  int get hashCode => Object.hashAll(items);
}

Coryn.provideState('cart', CorynCallbackStateProvider(() => CartState(cart.items)));
```

States must be immutable and `==` must agree with `toJson`. `getState` runs on the UI isolate every 100 ms while the
app is visible and every second in the background; only changed states are encoded and sent, in at most one
acknowledged batch at a time. A state class without `==` still works (unchanged JSON is not sent again), but it is
re-encoded on every tick. `getState`, `toJson` and `==` must only read: never register or remove providers from them.
