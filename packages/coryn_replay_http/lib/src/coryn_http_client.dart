import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:coryn_replay/coryn_replay.dart';
import 'package:coryn_replay/coryn_replay_internal.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Called with every report; return a modified copy to redact it further, or `null` to skip it.
typedef CorynApiRequestTransform = CorynApiRequest? Function(CorynApiRequest request);

/// An [http.Client] that records every request with `Coryn.addApiRequest`, like the Android OkHttp interceptor.
///
/// * Credentials in standard authentication/cookie headers and common secret URL parameters are redacted.
/// * Bodies are opt-in. Request bodies are recorded only for [http.Request] with a textual content type and at most
///   8,192 characters. Response previews read the first 8,192 characters as the app consumes the stream; the report is
///   sent when the body completes, fails or the preview is full, so leave [captureResponseBody] off for streams. A
///   previewable response whose body the app cancels or never reads before then is not reported.
/// * The original request and response pass through unchanged. UI hiding does not mask these fields.
/// * Nothing is recorded or copied while no session records ([Coryn.isRecording]), like the Android interceptor.
class CorynHttpClient extends http.BaseClient {
  CorynHttpClient({
    http.Client? inner,
    bool captureRequestBody = false,
    bool captureResponseBody = false,
    Set<String> redactedHeaders = const <String>{},
    Set<String> skippedHeaders = const <String>{},
    Set<String> redactedUrlParameters = const <String>{},
    Set<String> skippedUrlParameters = const <String>{},
    this.transform,
    void Function(CorynApiRequest request)? report,
  }) : _inner = inner ?? http.Client(),
       _report = report ?? Coryn.addApiRequest,
       _builder = CorynApiRequestBuilder(
         captureRequestBody: captureRequestBody,
         captureResponseBody: captureResponseBody,
         redactedHeaders: redactedHeaders,
         skippedHeaders: skippedHeaders,
         redactedUrlParameters: redactedUrlParameters,
         skippedUrlParameters: skippedUrlParameters,
       );

  final http.Client _inner;
  final CorynApiRequestBuilder _builder;
  final void Function(CorynApiRequest request) _report;
  final CorynApiRequestTransform? transform;
  bool _isCallbackFailureReported = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!Coryn.isRecording) return _inner.send(request);
    final startedAt = DateTime.now();
    final stopwatch = Stopwatch()..start();
    final requestBody = _builder.captureRequestBody ? _safeRequestBody(request) : null;
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (error) {
      _emit(
        () => _builder.build(
          url: request.url,
          method: request.method,
          duration: stopwatch.elapsed,
          startedAt: startedAt,
          requestHeaders: _entries(request.headers),
          requestBody: requestBody,
          error: error,
        ),
      );
      rethrow;
    }
    final duration = stopwatch.elapsed;
    // The report may be built after the app consumed the body: it records the headers as sent (finalized by the inner
    // client, which sets a multipart boundary) and received.
    final requestHeaders = _entries(request.headers);
    final responseHeaders = _entries(response.headers);
    final previewable =
        _builder.captureResponseBody &&
        CorynApiRequestBuilder.isPreviewableBody(response.headers['content-type'], _encodings(response.headers));
    CorynApiRequest build({String? body, bool isTruncated = false, bool isUnknown = false}) => _builder.build(
      url: request.url,
      method: request.method,
      duration: duration,
      startedAt: startedAt,
      requestHeaders: requestHeaders,
      requestBody: requestBody,
      responseCode: response.statusCode,
      responseHeaders: responseHeaders,
      responseBody: body,
      isResponseBodyTruncated: isTruncated,
      isResponseBodyTruncationUnknown: isUnknown,
    );
    if (!previewable) {
      _emit(build);
      return response;
    }
    final preview = _ResponsePreview(response.headers['content-type']);
    var isReported = false;
    void reportOnce({bool isUnknown = false}) {
      if (isReported) return;
      isReported = true;
      _emit(() {
        final (:text, :isTruncated) = preview.result;
        return build(body: text, isTruncated: isTruncated, isUnknown: isUnknown);
      });
    }

    // The app's bytes and errors are forwarded unchanged. The preview copies its bounded part of a chunk before the app
    // gets it, so an app changing the chunk in place cannot change the report.
    final stream = response.stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (List<int> data, EventSink<List<int>> sink) {
          preview.add(data);
          sink.add(data);
          if (preview.isFull) reportOnce();
        },
        handleError: (Object error, StackTrace stack, EventSink<List<int>> sink) {
          sink.addError(error, stack);
          reportOnce(isUnknown: true);
        },
        handleDone: (EventSink<List<int>> sink) {
          sink.close();
          reportOnce();
        },
      ),
    );
    if (response case http.BaseResponseWithUrl(:final url)) {
      return _StreamedResponseWithUrl(
        stream,
        response.statusCode,
        url: url,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    }
    return http.StreamedResponse(
      stream,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// Diagnostics never break the app's request. A failure to build the report is the SDK's and goes to the native
  /// error reporting; a failing [transform] or `report` callback, or the request's encoding, is the app's and goes to
  /// [FlutterError.reportError] once per client.
  void _emit(CorynApiRequest Function() build) {
    final CorynApiRequest request;
    try {
      if (!Coryn.isRecording) return;
      request = build();
    } catch (error, stack) {
      CorynSdkFailures.report('http: report', error, stack);
      return;
    }
    try {
      final transform = this.transform;
      final recorded = transform == null ? request : transform(request);
      if (recorded != null) _report(recorded);
    } catch (error, stack) {
      _reportCallbackFailure(error, stack);
    }
  }

  void _reportCallbackFailure(Object error, StackTrace stack) {
    if (_isCallbackFailureReported) return;
    _isCallbackFailureReported = true;
    try {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'coryn_replay_http',
          context: ErrorDescription('in an app callback or request conversion used by CorynHttpClient'),
          silent: kReleaseMode,
        ),
      );
    } catch (_) {
      // A failing app error handler must not replace the transport result.
    }
  }

  /// A body its declared encoding cannot decode is not previewed; any other failure is the SDK's.
  String? _safeRequestBody(http.BaseRequest request) {
    try {
      return _requestBody(request);
    } on FormatException {
      return null;
    } catch (error, stack) {
      CorynSdkFailures.report('http: request body preview', error, stack);
      return null;
    }
  }

  String? _requestBody(http.BaseRequest request) {
    if (request is! http.Request) return null;
    final isPreviewable = CorynApiRequestBuilder.isPreviewableBody(
      request.headers['content-type'],
      _encodings(request.headers),
    );
    if (!isPreviewable) return null;
    final isBounded = request.bodyBytes.length <= CorynApiRequestBuilder.maxFieldSize * 4;
    if (!isBounded) return null;
    final String body;
    try {
      body = request.body;
    } on FormatException {
      return null;
    } catch (error, stack) {
      // The request's encoding is app code.
      _reportCallbackFailure(error, stack);
      return null;
    }
    return body.length <= CorynApiRequestBuilder.maxFieldSize ? body : null;
  }

  static List<String> _encodings(Map<String, String> headers) {
    final value = headers['content-encoding'];
    return value == null ? const <String>[] : value.split(',');
  }

  static List<MapEntry<String, String>> _entries(Map<String, String> headers) =>
      headers.entries.toList(growable: false);

  @override
  void close() => _inner.close();
}

/// The previewed response keeps the final URL of a redirected response (`package:http` exposes it only this way).
final class _StreamedResponseWithUrl extends http.StreamedResponse implements http.BaseResponseWithUrl {
  _StreamedResponseWithUrl(
    super.stream,
    super.statusCode, {
    required this.url,
    super.contentLength,
    super.request,
    super.headers,
    super.isRedirect,
    super.persistentConnection,
    super.reasonPhrase,
  });

  @override
  final Uri url;
}

/// Keeps the first bytes of a textual body (enough for 8,192 characters) and decodes them only when reported, with a
/// decoder that never throws on malformed or split multi-byte sequences.
final class _ResponsePreview {
  _ResponsePreview(String? contentType) : _isLatin1 = Encoding.getByName(_charset(contentType)) == latin1;

  /// UTF-8 needs at most 4 bytes per character.
  static const int _maxBytes = CorynApiRequestBuilder.maxFieldSize * 4;

  final bool _isLatin1;
  final BytesBuilder _bytes = BytesBuilder(copy: true);
  bool _hasMore = false;

  /// Enough bytes were kept, or the body is longer than the preview.
  bool get isFull => _hasMore || _bytes.length >= _maxBytes;

  /// The previewed text and whether the body had more, from one decode.
  ({String text, bool isTruncated}) get result {
    final preview = CorynApiRequestBuilder.preview(_decode());
    return (text: preview.text, isTruncated: _hasMore || preview.isTruncated);
  }

  void add(List<int> data) {
    if (isFull) {
      _hasMore = true;
      return;
    }
    final remaining = _maxBytes - _bytes.length;
    final isTooLong = data.length > remaining;
    if (isTooLong) {
      _bytes.add(data.sublist(0, remaining));
      _hasMore = true;
      return;
    }
    _bytes.add(data);
  }

  String _decode() {
    final bytes = _bytes.toBytes();
    return _isLatin1 ? latin1.decode(bytes) : utf8.decode(bytes, allowMalformed: true);
  }

  static String? _charset(String? contentType) {
    if (contentType == null) return null;
    final match = RegExp(r'charset=([^;\s]+)', caseSensitive: false).firstMatch(contentType);
    final charset = match?.group(1)?.toLowerCase();
    if (charset == null) return null;
    final isQuoted = charset.length >= 2 && charset.startsWith('"') && charset.endsWith('"');
    return isQuoted ? charset.substring(1, charset.length - 1) : charset;
  }
}
