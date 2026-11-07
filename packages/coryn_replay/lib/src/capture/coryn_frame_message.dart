import 'dart:typed_data';

/// Frame header for the Kotlin `CorynFlutterFrameHeader`. The RGBA pixels are sent as the very next message on the
/// same channel, so they are never copied on the UI thread.
///
/// Layout (little endian, 48 bytes): `u8 type = 1`, `u8 version = 4`, `u16 reserved`, `u32 imageWidth`,
/// `u32 imageHeight`, `i32 rootLeft`, `i32 rootTop`, `u32 rootWidth`, `u32 rootHeight`, `u32 viewWidth`,
/// `u32 viewHeight`, `u32 generation`, `u32 timePassedMs`, `u32 geometryRevision`. Root and view values are physical
/// pixels of the Flutter view; the pixel message holds `imageWidth * imageHeight * 4` premultiplied RGBA bytes. The
/// generation (attachment of the sending isolate) is written by the platform bridge at [generationOffset]; the geometry
/// revision is the native view revision the frame was captured for.
abstract final class CorynFrameMessage {
  static const int type = 1;
  static const int version = 4;
  static const int headerSize = 48;
  static const int generationOffset = 36;

  static Uint8List header({
    required int imageWidth,
    required int imageHeight,
    required int rootLeft,
    required int rootTop,
    required int rootWidth,
    required int rootHeight,
    required int viewWidth,
    required int viewHeight,
    required int timePassedMs,
    required int geometryRevision,
  }) {
    final message = Uint8List(headerSize);
    ByteData.sublistView(message)
      ..setUint8(0, type)
      ..setUint8(1, version)
      ..setUint32(4, imageWidth, Endian.little)
      ..setUint32(8, imageHeight, Endian.little)
      ..setInt32(12, rootLeft, Endian.little)
      ..setInt32(16, rootTop, Endian.little)
      ..setUint32(20, rootWidth, Endian.little)
      ..setUint32(24, rootHeight, Endian.little)
      ..setUint32(28, viewWidth, Endian.little)
      ..setUint32(32, viewHeight, Endian.little)
      ..setUint32(40, timePassedMs, Endian.little)
      ..setUint32(44, geometryRevision, Endian.little);
    return message;
  }
}
