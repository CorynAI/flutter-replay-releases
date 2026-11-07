import 'package:coryn_replay/coryn_replay.dart';

/// JSON of decoded Dio data (`Map`, `List`, `String`, `num`, `bool`, `null`, objects with `toJson`), as
/// `jsonEncode` writes it but only up to [CorynApiRequestBuilder.maxFieldSize] characters: a large body, a long string
/// or a wide map costs no more than the preview. `null` when the data is not JSON-encodable.
({String text, bool isTruncated})? jsonPreview(Object? data) {
  final writer = _JsonPreviewWriter();
  try {
    writer.write(data);
  } on _PreviewFull {
    return CorynApiRequestBuilder.preview(writer.text);
  } catch (_) {
    return null;
  }
  return CorynApiRequestBuilder.preview(writer.text);
}

/// Stops the writer once the preview is full.
final class _PreviewFull implements Exception {
  const _PreviewFull();
}

final class _JsonPreviewWriter {
  final StringBuffer _buffer = StringBuffer();

  String get text => _buffer.toString();

  void _checkFull() {
    if (_buffer.length > CorynApiRequestBuilder.maxFieldSize) throw const _PreviewFull();
  }

  /// Writes [value]; an object that is not JSON gets one `toJson()` conversion, whose result must be JSON (its children
  /// may be converted again), as in `jsonEncode`.
  void write(Object? value, {bool isConverted = false}) {
    _checkFull();
    switch (value) {
      case null:
        _buffer.write('null');
      case bool():
        _buffer.write(value);
      case num():
        if (!value.isFinite) throw UnsupportedError('JSON has no $value');
        _buffer.write(value);
      case String():
        _writeString(value);
      case List<Object?>():
        _buffer.write('[');
        for (var i = 0; i < value.length; i++) {
          if (i > 0) _buffer.write(',');
          write(value[i]);
        }
        _buffer.write(']');
      case Map<Object?, Object?>():
        _buffer.write('{');
        var isFirst = true;
        for (final MapEntry<Object?, Object?>(:key, value: item) in value.entries) {
          if (key is! String) throw UnsupportedError('JSON map keys are strings');
          if (!isFirst) _buffer.write(',');
          isFirst = false;
          _writeString(key);
          _buffer.write(':');
          write(item);
        }
        _buffer.write('}');
      default:
        if (isConverted) throw UnsupportedError('toJson() did not return JSON');
        final Object? json = (value as dynamic).toJson();
        write(json, isConverted: true);
    }
    _checkFull();
  }

  /// Escapes like `jsonEncode` (quotes, backslashes, control characters, unpaired surrogates), one code unit at a time,
  /// checking for a full preview at least every 256 code units.
  void _writeString(String value) {
    _buffer.write('"');
    var nextCheck = 0;
    for (var i = 0; i < value.length; i++) {
      if (i >= nextCheck) {
        _checkFull();
        nextCheck = i + 256;
      }
      final unit = value.codeUnitAt(i);
      if (unit >= 0x20 && unit != 0x22 && unit != 0x5C && !_isSurrogate(unit)) {
        _buffer.writeCharCode(unit);
        continue;
      }
      final isPairStart = _isLead(unit) && i + 1 < value.length && _isTrail(value.codeUnitAt(i + 1));
      if (isPairStart) {
        _buffer
          ..writeCharCode(unit)
          ..writeCharCode(value.codeUnitAt(i + 1));
        i++;
        continue;
      }
      _buffer.write(_escape(unit));
    }
    _buffer.write('"');
  }

  static bool _isSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDFFF;

  static bool _isLead(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  static bool _isTrail(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  static String _escape(int unit) => switch (unit) {
    0x08 => r'\b',
    0x09 => r'\t',
    0x0A => r'\n',
    0x0C => r'\f',
    0x0D => r'\r',
    0x22 => r'\"',
    0x5C => r'\\',
    _ => '\\u${unit.toRadixString(16).padLeft(4, '0')}',
  };
}
