# coryn_replay_http

Records [`package:http`](https://pub.dev/packages/http) requests as Coryn API request events, with the same redaction
rules as the Coryn Android OkHttp interceptor. Needs [`coryn_replay`](../coryn_replay).

Use the same release tag for both packages:

```yaml
dependencies:
  coryn_replay:
    git:
      url: https://github.com/CorynAI/flutter-replay-releases.git
      path: packages/coryn_replay
      ref: v0.2.0
  coryn_replay_http:
    git:
      url: https://github.com/CorynAI/flutter-replay-releases.git
      path: packages/coryn_replay_http
      ref: v0.2.0
```

```dart
final client = CorynHttpClient(); // wraps http.Client(), or pass inner: yourClient
final response = await client.get(Uri.parse('https://api.example.com/items'));
```

Credentials in standard authentication and cookie headers and common secret URL parameters are redacted; add your own
with `redactedHeaders`, `skippedHeaders`, `redactedUrlParameters` and `skippedUrlParameters`, or rewrite or drop a report
with `transform`. Bodies are opt-in (`captureRequestBody`, `captureResponseBody`). Request bodies are recorded only for
`http.Request` with a textual content type and at most 8,192 characters; response previews are read as the app consumes
the stream, so leave `captureResponseBody` off for streams. UI hiding does not mask these fields. Nothing is recorded
while no session records.
