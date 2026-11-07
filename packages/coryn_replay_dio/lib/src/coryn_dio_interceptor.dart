import 'dart:convert';
import 'dart:typed_data';

import 'package:coryn_replay/coryn_replay.dart';
import 'package:dio/dio.dart';

import 'coryn_json_preview.dart';

/// Called with every report; return a modified copy to redact it further, or `null` to skip it.
typedef CorynDioRequestTransform = CorynApiRequest? Function(CorynApiRequest request);

/// A Dio interceptor that records every request with `Coryn.addApiRequest`, like the Android OkHttp interceptor.
///
/// Add it last so it sees the final request: `dio.interceptors.add(CorynDioInterceptor())`.
/// Credentials in standard authentication/cookie headers and common secret URL parameters are redacted. Bodies are
/// opt-in and recorded only when textual and at most 8,192 characters (`String`, `Map`/`List` JSON, form data
/// fields are skipped; streamed responses are never read; bytes are decoded as UTF-8). UI hiding does not mask these
/// fields. Nothing is recorded while no session records ([Coryn.isRecording]), like the Android interceptor.
class CorynDioInterceptor extends Interceptor {
  CorynDioInterceptor({
    bool captureRequestBody = false,
    bool captureResponseBody = false,
    Set<String> redactedHeaders = const <String>{},
    Set<String> skippedHeaders = const <String>{},
    Set<String> redactedUrlParameters = const <String>{},
    Set<String> skippedUrlParameters = const <String>{},
    this.transform,
    void Function(CorynApiRequest request)? report,
  }) : _report = report ?? Coryn.addApiRequest,
       _builder = CorynApiRequestBuilder(
         captureRequestBody: captureRequestBody,
         captureResponseBody: captureResponseBody,
         redactedHeaders: redactedHeaders,
         skippedHeaders: skippedHeaders,
         redactedUrlParameters: redactedUrlParameters,
         skippedUrlParameters: skippedUrlParameters,
       );

  static const String _startKey = 'coryn_replay.startedAt';
  static const String _stopwatchKey = 'coryn_replay.stopwatch';

  final CorynApiRequestBuilder _builder;
  final void Function(CorynApiRequest request) _report;
  final CorynDioRequestTransform? transform;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (Coryn.isRecording) {
      options.extra[_startKey] = DateTime.now();
      options.extra[_stopwatchKey] = Stopwatch()..start();
    }
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _record(response.requestOptions, response, null);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _record(err.requestOptions, err.response, err.response == null ? err.error ?? err : null);
    handler.next(err);
  }

  void _record(RequestOptions options, Response<dynamic>? response, Object? error) {
    try {
      final startedAt = options.extra[_startKey] as DateTime?;
      final stopwatch = options.extra[_stopwatchKey] as Stopwatch?;
      final isRecorded = startedAt != null && stopwatch != null && Coryn.isRecording;
      if (!isRecorded) return;
      final responseHeaders = response?.headers;
      final responseBody = response == null ? null : _responseBody(response);
      final report = _builder.build(
        url: options.uri,
        method: options.method,
        duration: stopwatch.elapsed,
        startedAt: startedAt,
        requestHeaders: _requestHeaders(options),
        requestBody: _builder.captureRequestBody ? _requestBody(options) : null,
        responseCode: response?.statusCode,
        responseHeaders: responseHeaders == null ? const <MapEntry<String, String>>[] : _entries(responseHeaders.map),
        responseBody: responseBody?.text,
        isResponseBodyTruncated: responseBody?.isTruncated ?? false,
        error: error,
      );
      final transform = this.transform;
      final recorded = transform == null ? report : transform(report);
      if (recorded != null) _report(recorded);
    } catch (_) {
      // Diagnostics must never break the app's request.
    }
  }

  static List<MapEntry<String, String>> _requestHeaders(RequestOptions options) {
    final entries = <MapEntry<String, String>>[];
    options.headers.forEach((String key, Object? value) {
      if (value is Iterable<Object?>) {
        for (final item in value) {
          entries.add(MapEntry<String, String>(key, '$item'));
        }
      } else if (value != null) {
        entries.add(MapEntry<String, String>(key, '$value'));
      }
    });
    final contentType = options.contentType;
    final hasContentType = options.headers.keys.any((String key) => key.toLowerCase() == 'content-type');
    if (contentType != null && !hasContentType) entries.add(MapEntry<String, String>('content-type', contentType));
    return entries;
  }

  static List<MapEntry<String, String>> _entries(Map<String, List<String>> map) => <MapEntry<String, String>>[
    for (final MapEntry<String, List<String>>(:key, :value) in map.entries)
      for (final item in value) MapEntry<String, String>(key, item),
  ];

  /// A request body is recorded whole or not at all, like the Android interceptor.
  static String? _requestBody(RequestOptions options) {
    final contentType = options.contentType ?? options.headers['content-type']?.toString();
    final encodings = _contentEncodings(options.headers);
    final isPreviewable = CorynApiRequestBuilder.isPreviewableBody(contentType ?? 'application/json', encodings);
    if (!isPreviewable) return null;
    final preview = _preview(options.data);
    if (preview == null || preview.isTruncated) return null;
    return preview.text;
  }

  /// `Content-Encoding` values of request [headers] (any key case, lists and comma-separated values).
  static List<String> _contentEncodings(Map<String, Object?> headers) {
    final encodings = <String>[];
    for (final MapEntry<String, Object?>(:key, :value) in headers.entries) {
      if (key.toLowerCase() != 'content-encoding') continue;
      final values = value is Iterable<Object?> ? value : <Object?>[value];
      for (final item in values) {
        if (item != null) encodings.addAll('$item'.split(','));
      }
    }
    return encodings;
  }

  ({String text, bool isTruncated})? _responseBody(Response<dynamic> response) {
    if (!_builder.captureResponseBody) return null;
    final headers = response.headers;
    final isPreviewable = CorynApiRequestBuilder.isPreviewableBody(
      headers.value(Headers.contentTypeHeader),
      headers[Headers.contentEncodingHeader] ?? const <String>[],
    );
    if (!isPreviewable) return null;
    return _preview(response.data);
  }

  /// At most [CorynApiRequestBuilder.maxFieldSize] characters of a body: text as is, bytes decoded as UTF-8 and decoded
  /// JSON (`Map`/`List`) re-encoded. The work is bounded by the preview, not by the body. `null` for anything else.
  static ({String text, bool isTruncated})? _preview(Object? data) => switch (data) {
    String() => CorynApiRequestBuilder.preview(data),
    final Uint8List bytes => _decode(bytes),
    final Map<Object?, Object?> map => jsonPreview(map),
    final List<Object?> list => jsonPreview(list),
    _ => null,
  };

  /// Bytes (`ResponseType.bytes`, raw request bodies) as UTF-8 text, at most [CorynApiRequestBuilder.maxFieldSize]
  /// characters; only the bytes that can hold them are decoded.
  static ({String text, bool isTruncated}) _decode(Uint8List bytes) {
    const maxBytes = CorynApiRequestBuilder.maxFieldSize * 4;
    final hasMoreBytes = bytes.length > maxBytes;
    final head = hasMoreBytes ? Uint8List.sublistView(bytes, 0, maxBytes) : bytes;
    final preview = CorynApiRequestBuilder.preview(utf8.decode(head, allowMalformed: true));
    return (text: preview.text, isTruncated: hasMoreBytes || preview.isTruncated);
  }
}
