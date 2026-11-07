import 'dart:collection';

import 'coryn_api_request.dart';

/// Builds [CorynApiRequest] reports with the same rules as the Android OkHttp interceptor:
/// default credential redaction, skipped/redacted names (case-insensitive), text-only bounded body previews,
/// endpoint without query, and the native size limits.
///
/// Used by `coryn_replay_http` and `coryn_replay_dio`; other HTTP stacks can use it directly.
final class CorynApiRequestBuilder {
  CorynApiRequestBuilder({
    this.captureRequestBody = false,
    this.captureResponseBody = false,
    Set<String> redactedHeaders = const <String>{},
    Set<String> skippedHeaders = const <String>{},
    Set<String> redactedUrlParameters = const <String>{},
    Set<String> skippedUrlParameters = const <String>{},
  }) : _redactedHeaders = _lowercase(<String>{...defaultRedactedHeaders, ...redactedHeaders}),
       _skippedHeaders = _lowercase(skippedHeaders),
       _redactedParameters = _lowercase(<String>{...defaultRedactedUrlParameters, ...redactedUrlParameters}),
       _skippedParameters = _lowercase(skippedUrlParameters);

  /// Header names always redacted, as in the Android interceptor.
  static const Set<String> defaultRedactedHeaders = <String>{
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
  };

  /// URL parameter names always redacted, as in the Android interceptor.
  static const Set<String> defaultRedactedUrlParameters = <String>{
    'access_token',
    'token',
    'api_key',
    'apikey',
    'key',
    'password',
    'secret',
  };

  /// Native limits (`CorynApiRequestConstants`).
  static const int maxFieldSize = 8192;
  static const int maxTotalCharacters = 16384;
  static const int maxEntries = 64;
  static const int maxValues = 16;
  static const String redactedValue = '<redacted>';

  final bool captureRequestBody;
  final bool captureResponseBody;
  final Set<String> _redactedHeaders;
  final Set<String> _skippedHeaders;
  final Set<String> _redactedParameters;
  final Set<String> _skippedParameters;

  static Set<String> _lowercase(Set<String> names) => names.map((String name) => name.toLowerCase()).toSet();

  /// Whether a body with [contentType] and [contentEncoding] may be previewed: textual, not streaming, not content-coded.
  static bool isPreviewableBody(String? contentType, List<String> contentEncodings) {
    final isContentCoded = contentEncodings.any((String value) => value.trim().toLowerCase() != 'identity');
    if (isContentCoded) return false;
    if (contentType == null) return false;
    final mediaType = contentType.split(';').first.trim().toLowerCase();
    final slash = mediaType.indexOf('/');
    if (slash <= 0) return false;
    final type = mediaType.substring(0, slash);
    final subtype = mediaType.substring(slash + 1);
    final isStreaming = subtype == 'event-stream' || subtype == 'x-ndjson' || subtype == 'json-seq';
    if (isStreaming) return false;
    return type == 'text' ||
        subtype == 'json' ||
        subtype.endsWith('+json') ||
        subtype == 'xml' ||
        subtype.endsWith('+xml') ||
        subtype == 'x-www-form-urlencoded';
  }

  /// The first [maxFieldSize] characters of [text], never splitting a surrogate pair, and whether text was cut.
  static ({String text, bool isTruncated}) preview(String text) {
    if (text.length <= maxFieldSize) return (text: text, isTruncated: false);
    return (text: _MetadataCollector._safePrefix(text, maxFieldSize), isTruncated: true);
  }

  /// Creates the report. [requestBody] and [responseBody] must already be limited to [maxFieldSize] characters;
  /// pass [isResponseBodyTruncated] when the response had more data than the preview.
  CorynApiRequest build({
    required Uri url,
    required String method,
    required Duration duration,
    required DateTime startedAt,
    required List<MapEntry<String, String>> requestHeaders,
    String? requestBody,
    int? responseCode,
    List<MapEntry<String, String>> responseHeaders = const <MapEntry<String, String>>[],
    String? responseBody,
    bool isResponseBodyTruncated = false,
    bool isResponseBodyTruncationUnknown = false,
    Object? error,
  }) {
    final collector = _MetadataCollector(_skippedHeaders, _redactedHeaders, _skippedParameters, _redactedParameters);
    final parameters = collector.parameters(url);
    final headers = collector.headers(requestHeaders);
    final hasResponse = responseCode != null;
    final recordedResponseHeaders = hasResponse ? collector.headers(responseHeaders) : null;
    final endpoint = _endpoint(url);
    final isMetadataTruncated =
        parameters.isTruncated ||
        headers.isTruncated ||
        (recordedResponseHeaders?.isTruncated ?? false) ||
        endpoint.isTruncated;
    final recordedResponseBody = captureResponseBody ? responseBody : null;
    final truncation = _truncation(
      isMetadataTruncated,
      recordedResponseBody,
      isResponseBodyTruncated,
      isResponseBodyTruncationUnknown,
    );
    return CorynApiRequest(
      endpoint: endpoint.value,
      method: method,
      durationMs: duration.inMilliseconds < 0 ? 0 : duration.inMilliseconds,
      headers: headers.values,
      body: captureRequestBody ? requestBody : null,
      urlParams: parameters.values,
      responseCode: responseCode,
      responseHeaders: recordedResponseHeaders?.values ?? const <String, List<String>>{},
      responseBody: recordedResponseBody,
      error: error?.runtimeType.toString(),
      startedAtUnixMs: startedAt.millisecondsSinceEpoch,
      truncation: truncation,
    );
  }

  static CorynApiRequestTruncation? _truncation(
    bool isMetadataTruncated,
    String? responseBody,
    bool isResponseBodyTruncated,
    bool isResponseBodyTruncationUnknown,
  ) {
    if (isMetadataTruncated) return CorynApiRequestTruncation.truncated;
    if (responseBody == null) return null;
    if (isResponseBodyTruncated) return CorynApiRequestTruncation.truncated;
    if (isResponseBodyTruncationUnknown) return CorynApiRequestTruncation.unknown;
    return null;
  }

  static ({String value, bool isTruncated}) _endpoint(Uri url) {
    final result = StringBuffer();
    final isIpv6 = url.host.contains(':');
    final port = url.hasPort && url.port != _defaultPort(url.scheme) ? ':${url.port}' : '';
    final parts = <String>[url.scheme, '://', if (isIpv6) '[', url.host, if (isIpv6) ']', port];
    for (final part in parts) {
      final remaining = maxFieldSize - result.length;
      final isTruncated = part.length > remaining;
      if (isTruncated) {
        result.write(part.substring(0, remaining));
        return (value: result.toString(), isTruncated: true);
      }
      result.write(part);
    }
    final path = url.hasEmptyPath ? '' : url.path;
    final remaining = maxFieldSize - result.length;
    final isPathTruncated = path.length > remaining;
    result.write(isPathTruncated ? path.substring(0, remaining) : path);
    return (value: result.toString(), isTruncated: isPathTruncated);
  }

  static int _defaultPort(String scheme) => switch (scheme) {
    'http' => 80,
    'https' => 443,
    _ => -1,
  };
}

final class _MetadataEntry {
  _MetadataEntry(this.name, this.isRedacted);

  final String name;
  final bool isRedacted;
  final List<String> values = <String>[];
}

final class _Metadata {
  _Metadata(this.values, this.isTruncated);

  final Map<String, List<String>> values;
  final bool isTruncated;
}

/// Port of `CorynApiRequestMetadataCollector`: the character budget is shared by every map of one report.
final class _MetadataCollector {
  _MetadataCollector(this._skippedHeaders, this._redactedHeaders, this._skippedParameters, this._redactedParameters);

  final Set<String> _skippedHeaders;
  final Set<String> _redactedHeaders;
  final Set<String> _skippedParameters;
  final Set<String> _redactedParameters;
  int _remaining = CorynApiRequestBuilder.maxTotalCharacters;
  bool _truncated = false;

  _Metadata headers(List<MapEntry<String, String>> headers) {
    _truncated = false;
    final entries = SplayTreeMap<String, _MetadataEntry>(
      (String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    for (final header in headers) {
      final shouldContinue = _add(entries, header.key, header.value, _skippedHeaders, _redactedHeaders);
      if (!shouldContinue) break;
    }
    return _result(entries);
  }

  _Metadata parameters(Uri url) {
    _truncated = false;
    final entries = <String, _MetadataEntry>{};
    for (final parameter in url.queryParametersAll.entries) {
      var shouldContinue = true;
      for (final value in parameter.value) {
        shouldContinue = _add(entries, parameter.key, value, _skippedParameters, _redactedParameters);
        if (!shouldContinue) break;
      }
      if (!shouldContinue) break;
    }
    return _result(entries);
  }

  _Metadata _result(Map<String, _MetadataEntry> entries) {
    final values = <String, List<String>>{for (final entry in entries.values) entry.name: entry.values};
    return _Metadata(values, _truncated);
  }

  bool _add(Map<String, _MetadataEntry> entries, String name, String value, Set<String> skipped, Set<String> redacted) {
    final lowerName = name.toLowerCase();
    if (skipped.contains(lowerName)) return true;
    final existing = entries[name];
    if (existing != null) return _addValue(existing, value);
    final isFull = entries.length == CorynApiRequestBuilder.maxEntries || _remaining == 0;
    if (isFull) {
      _truncated = true;
      return false;
    }
    final isRedacted = redacted.contains(lowerName);
    final entry = _MetadataEntry(_text(name), isRedacted);
    entries[name] = entry;
    if (_remaining == 0) {
      _truncated = true;
      return false;
    }
    entry.values.add(_text(isRedacted ? CorynApiRequestBuilder.redactedValue : value));
    return true;
  }

  bool _addValue(_MetadataEntry entry, String value) {
    if (entry.isRedacted) return true;
    final isFull = entry.values.length == CorynApiRequestBuilder.maxValues;
    if (isFull) {
      _truncated = true;
      return true;
    }
    if (_remaining == 0) {
      _truncated = true;
      return false;
    }
    entry.values.add(_text(value));
    return true;
  }

  String _text(String value) {
    var count = value.length;
    if (_remaining < count) count = _remaining;
    if (CorynApiRequestBuilder.maxFieldSize < count) count = CorynApiRequestBuilder.maxFieldSize;
    final isTruncated = count < value.length;
    if (isTruncated) _truncated = true;
    _remaining -= count;
    return _safePrefix(value, count);
  }

  /// Does not split a UTF-16 surrogate pair, like the native `safePrefix`.
  static String _safePrefix(String value, int count) {
    if (count >= value.length) return value;
    if (count <= 0) return '';
    final last = value.codeUnitAt(count - 1);
    final next = value.codeUnitAt(count);
    final isSurrogatePair = last >= 0xD800 && last <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF;
    return value.substring(0, isSurrogatePair ? count - 1 : count);
  }
}
