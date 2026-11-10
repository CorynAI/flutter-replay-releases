# Coryn Session Replay SDK for Flutter

Release builds of the Coryn Session Replay SDK for Flutter. Android records sessions through the Coryn Android SDK; on
other platforms every call is a no-op.

| Package | Purpose |
|---|---|
| [`coryn_replay`](packages/coryn_replay) | Core plugin: setup, UI capture with masking, states, screens, events, errors |
| [`coryn_replay_http`](packages/coryn_replay_http) | `CorynHttpClient` for `package:http` |
| [`coryn_replay_dio`](packages/coryn_replay_dio) | `CorynDioInterceptor` for Dio |

## Install

Add the packages as git dependencies at a release tag (the latest is `v0.2.0`), with the same tag for all of them:

```yaml
dependencies:
  coryn_replay:
    git:
      url: https://github.com/CorynAI/flutter-replay-releases.git
      path: packages/coryn_replay
      ref: v0.2.0
```

The Android app also needs the Coryn Maven repository, `minSdk` 26 or higher and `compileSdk` 36 or higher; see
[`packages/coryn_replay/README.md`](packages/coryn_replay/README.md) for setup and usage. Release notes are in each
package's `CHANGELOG.md`.

## License

See [LICENSE](LICENSE).
