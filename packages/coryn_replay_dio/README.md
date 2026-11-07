# coryn_replay_dio

Records [Dio](https://pub.dev/packages/dio) requests as Coryn API request events, with the same redaction rules as the
Coryn Android OkHttp interceptor. Needs [`coryn_replay`](../coryn_replay).

Use the same release tag for both packages:

```yaml
dependencies:
  coryn_replay:
    git:
      url: https://github.com/CorynAI/flutter-replay-releases.git
      path: packages/coryn_replay
      ref: v0.1.0
  coryn_replay_dio:
    git:
      url: https://github.com/CorynAI/flutter-replay-releases.git
      path: packages/coryn_replay_dio
      ref: v0.1.0
```

```dart
final dio = Dio();
dio.interceptors.add(CorynDioInterceptor()); // add it last so it sees the final request
```

Credentials in standard authentication and cookie headers and common secret URL parameters are redacted; add your own
with `redactedHeaders`, `skippedHeaders`, `redactedUrlParameters` and `skippedUrlParameters`, or rewrite or drop a report
with `transform`. Bodies are opt-in (`captureRequestBody`, `captureResponseBody`) and recorded only when textual and at
most 8,192 characters; streamed responses are never read. UI hiding does not mask these fields. Nothing is recorded
while no session records.
