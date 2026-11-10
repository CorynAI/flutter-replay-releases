## 0.2.0

* Request bodies are previewed in `onRequest`, as Dio's default transformer and encoding send them: data the app
  changes before the response is not recorded.
* A request with a custom `requestEncoder` records no request body unless its data is a `Uint8List`, which Dio sends
  unencoded.
* A request body without a textual content type is not recorded: Dio sends `Uint8List` data untyped unless the app
  sets one.
* Requests whose options have an unmodifiable `extra` map no longer fail while recording, and requests sharing one
  `extra` map are no longer recorded with each other's start time and body.
* Request data holding objects with `toJson` records no request body: the preview no longer converts them, so a
  `toJson` with side effects (a counter, a nonce) runs once, as without the interceptor.

## 0.1.0

* First release: `CorynDioInterceptor` records Dio requests as Coryn API request events.
