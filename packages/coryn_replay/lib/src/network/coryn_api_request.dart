/// Whether recorded API request data was shortened. Mirrors the Android `CorynApiRequestTruncation`.
enum CorynApiRequestTruncation {
  /// At least one field was shortened because of a size limit.
  truncated('TRUNCATED'),

  /// The reporter cannot tell whether all data is complete.
  unknown('UNKNOWN');

  const CorynApiRequestTruncation(this.nativeName);

  /// Name of the Android enum constant.
  final String nativeName;
}

/// A completed HTTP request reported with `Coryn.addApiRequest`. Mirrors the Android `Coryn.addApiRequest` parameters.
///
/// UI hiding does not mask these fields: omit or redact sensitive values before reporting. The native recorder keeps at
/// most 16,384 text characters, 64 entries per map, 16 values per entry and 8,192 characters per string.
final class CorynApiRequest {
  const CorynApiRequest({
    required this.endpoint,
    required this.method,
    required this.durationMs,
    this.headers = const <String, List<String>>{},
    this.body,
    this.urlParams = const <String, List<String>>{},
    this.responseCode,
    this.responseHeaders = const <String, List<String>>{},
    this.responseBody,
    this.error,
    this.startedAtUnixMs,
    this.truncation = CorynApiRequestTruncation.unknown,
  });

  /// Endpoint without query, for example `https://api.example.com/v1/users`.
  final String endpoint;
  final String method;

  /// Time until the response arrived or the request failed: `CorynHttpClient` stops at the response headers,
  /// `CorynDioInterceptor` when Dio hands the response or error to its interceptors (after the body was read).
  final int durationMs;
  final Map<String, List<String>> headers;
  final String? body;
  final Map<String, List<String>> urlParams;
  final int? responseCode;
  final Map<String, List<String>> responseHeaders;
  final String? responseBody;

  /// Error type name for transport failures, for example `SocketException` (may be an alias with `--obfuscate`).
  final String? error;
  final int? startedAtUnixMs;

  /// `null` means the reporter verified that every field is complete.
  final CorynApiRequestTruncation? truncation;

  Map<String, Object?> toMap() => <String, Object?>{
    'endpoint': endpoint,
    'method': method,
    'durationMs': durationMs,
    'headers': headers,
    'body': body,
    'urlParams': urlParams,
    'responseCode': responseCode,
    'responseHeaders': responseHeaders,
    'responseBody': responseBody,
    'error': error,
    'startedAtUnixMs': startedAtUnixMs,
    'truncation': truncation?.nativeName,
  };
}
