import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../capture/coryn_frame_message.dart';
import '../configuration.dart';
import '../network/coryn_api_request.dart';
import '../state/coryn_state_batch.dart';
import 'coryn_platform.dart';

/// Android implementation: talks to the Kotlin plugin, which calls the Coryn Android SDK.
///
/// Channels:
/// * `ai.coryn.replay/methods`: SDK calls (standard codec, Android main thread).
/// * `ai.coryn.replay/control`: native callbacks (capture start/stop, recording started).
/// * `ai.coryn.replay/states`: binary state batches, handled on a background task queue.
/// * `ai.coryn.replay/frames`: binary frames and UI-unchanged ticks, handled on a background task queue.
final class MethodChannelCorynPlatform implements CorynPlatform {
  MethodChannelCorynPlatform({BinaryMessenger? messenger})
    : _methods = MethodChannel(methodsChannelName, const StandardMethodCodec(), messenger),
      _control = MethodChannel(controlChannelName, const StandardMethodCodec(), messenger),
      _states = BasicMessageChannel<ByteData>(statesChannelName, const BinaryCodec(), binaryMessenger: messenger),
      _frames = BasicMessageChannel<ByteData>(framesChannelName, const BinaryCodec(), binaryMessenger: messenger);

  static const String methodsChannelName = 'ai.coryn.replay/methods';
  static const String controlChannelName = 'ai.coryn.replay/control';
  static const String statesChannelName = 'ai.coryn.replay/states';
  static const String framesChannelName = 'ai.coryn.replay/frames';

  /// Message type bytes of the frames channel.
  static const int frameMessageType = 1;
  static const int unchangedMessageType = 2;

  final MethodChannel _methods;
  final MethodChannel _control;
  final BasicMessageChannel<ByteData> _states;
  final BasicMessageChannel<ByteData> _frames;
  static final ByteData _unchangedMessage = ByteData(1)..setUint8(0, unchangedMessageType);

  /// Attachment generation from the last `attach`; native drops messages of other generations.
  int _generation = 0;

  @override
  bool get isSupported => true;

  @override
  Future<CorynNativeStatus> attach(CorynPlatformListener listener) async {
    _control.setMethodCallHandler((MethodCall call) => _onControl(listener, call));
    final status = await _methods.invokeMapMethod<String, Object?>('attach') ?? const <String, Object?>{};
    _generation = status['generation']! as int;
    final targetFps = status['captureTargetFps'] as num?;
    return CorynNativeStatus(
      captureTargetFps: targetFps?.toDouble(),
      sessionId: status['sessionId'] as String?,
      geometryRevision: status['geometryRevision'] as int? ?? 0,
      isRecordingStopped: status['isRecordingStopped'] as bool? ?? false,
    );
  }

  Future<void> _onControl(CorynPlatformListener listener, MethodCall call) async {
    final arguments = call.arguments;
    switch (call.method) {
      case 'captureStart':
        final map = arguments as Map<Object?, Object?>;
        listener.onCaptureStart((map['targetFps']! as num).toDouble());
      case 'captureStop':
        listener.onCaptureStop();
      case 'captureInvalidate':
        final map = arguments as Map<Object?, Object?>;
        listener.onCaptureInvalidate(map['geometryRevision']! as int);
      case 'captureReady':
        listener.onCaptureReady();
      case 'recordingStarted':
        final map = arguments as Map<Object?, Object?>;
        listener.onRecordingStarted(map['sessionId']! as String);
      case 'recordingStopped':
        listener.onRecordingStopped();
      default:
        throw MissingPluginException('Unknown Coryn control call ${call.method}');
    }
  }

  @override
  Future<void> init(String apiKey, CorynConfiguration? configuration) {
    return _methods.invokeMethod<void>('init', <String, Object?>{
      'apiKey': apiKey,
      'configuration': configuration?.toMap(),
    });
  }

  @override
  Future<void> startRecording(String? delayReason, CorynRecordingConfiguration? configuration) {
    return _methods.invokeMethod<void>('startRecording', <String, Object?>{
      'delayReason': delayReason,
      'configuration': configuration?.toMap(),
    });
  }

  @override
  Future<void> stopRecording(String? reason) {
    return _methods.invokeMethod<void>('stopRecording', <String, Object?>{'reason': reason});
  }

  @override
  Future<int> registerScreen(String name, Map<String, Object>? arguments) async {
    final handle = await _methods.invokeMethod<int>('registerScreen', <String, Object?>{
      'name': name,
      'arguments': arguments,
    });
    return handle!;
  }

  @override
  Future<void> unregisterScreen(int handle) {
    return _methods.invokeMethod<void>('unregisterScreen', <String, Object?>{'handle': handle});
  }

  @override
  Future<void> addEvent(String eventId, String? stateJson, int timePassedMs) {
    return _methods.invokeMethod<void>('addEvent', <String, Object?>{
      'eventId': eventId,
      'stateJson': stateJson,
      'timePassedMs': timePassedMs,
    });
  }

  @override
  Future<void> addApiRequest(CorynApiRequest request) {
    return _methods.invokeMethod<void>('addApiRequest', request.toMap());
  }

  @override
  Future<void> showToast(String text, bool isLong) {
    return _methods.invokeMethod<void>('showToast', <String, Object?>{'text': text, 'isLong': isLong});
  }

  @override
  Future<bool> sendStateBatch(Uint8List batch) async {
    final data = ByteData.sublistView(batch)
      ..setUint32(CorynStateBatchWriter.generationOffset, _generation, Endian.little);
    final reply = await _states.send(data);
    return reply != null && reply.lengthInBytes > 0 && reply.getUint8(0) == 0;
  }

  @override
  Future<CorynFrameResult> sendFrame(Uint8List header, ByteData pixels) async {
    final data = ByteData.sublistView(header)
      ..setUint32(CorynFrameMessage.generationOffset, _generation, Endian.little);
    // Both messages are queued now, in order, on the same channel; native pairs the pixels with the header before them.
    unawaited(_frames.send(data));
    final reply = await _frames.send(pixels);
    final code = reply == null || reply.lengthInBytes == 0 ? CorynFrameResult.rejected.index : reply.getUint8(0);
    return CorynFrameResult.values[code];
  }

  @override
  Future<bool> sendUiUnchanged() async {
    final reply = await _frames.send(_unchangedMessage);
    return reply != null && reply.lengthInBytes > 0 && reply.getUint8(0) == 0;
  }

  @override
  Future<Map<String, Object?>> debugStats() async {
    final stats = await _methods.invokeMapMethod<String, Object?>('debugStats');
    return stats ?? const <String, Object?>{};
  }
}
