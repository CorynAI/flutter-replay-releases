import 'dart:convert';
import 'dart:typed_data';

/// Binary state batch, decoded by the Kotlin `CorynFlutterStateBatchDecoder`.
///
/// Layout (little endian): `u8 version`, `u32 generation`, `u32 count`, then per entry `u8 operation`, `u32 keyLength`,
/// key UTF-8 and, for [putOperation] and [failureOperation], `u32 length` and the UTF-8 JSON or failure message.
/// The generation (attachment of the sending isolate) is written by the platform bridge at [generationOffset].
final class CorynStateBatchWriter {
  static const int version = 2;
  static const int generationOffset = 1;
  static const int headerSize = 9;
  static const int putOperation = 1;
  static const int removeOperation = 2;
  static const int missingOperation = 3;
  static const int failureOperation = 4;

  final BytesBuilder _body = BytesBuilder(copy: false);
  int _count = 0;

  int get count => _count;

  /// Bytes written so far, header excluded.
  int get length => _body.length;

  bool get isEmpty => _count == 0;

  /// The state of [key] is [json].
  void put(String key, Uint8List json) {
    _body.addByte(putOperation);
    _addBytes(utf8.encode(key));
    _addBytes(json);
    _count++;
  }

  /// The provider of [key] was removed.
  void remove(String key) {
    _body.addByte(removeOperation);
    _addBytes(utf8.encode(key));
    _count++;
  }

  /// The provider of [key] returned `null`: the state is finished.
  void missing(String key) {
    _body.addByte(missingOperation);
    _addBytes(utf8.encode(key));
    _count++;
  }

  /// The provider of [key] failed; native reports it through its provider failure policy.
  void failure(String key, String message) {
    _body.addByte(failureOperation);
    _addBytes(utf8.encode(key));
    _addBytes(utf8.encode(message));
    _count++;
  }

  void _addBytes(List<int> bytes) {
    final length = Uint8List(4);
    ByteData.sublistView(length).setUint32(0, bytes.length, Endian.little);
    _body.add(length);
    _body.add(bytes);
  }

  Uint8List build() {
    final body = _body.takeBytes();
    final result = Uint8List(headerSize + body.length);
    final header = ByteData.sublistView(result, 0, headerSize);
    header.setUint8(0, version);
    header.setUint32(5, _count, Endian.little);
    result.setRange(headerSize, result.length, body);
    _count = 0;
    return result;
  }
}
