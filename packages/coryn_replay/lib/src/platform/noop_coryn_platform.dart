import 'dart:typed_data';

import '../configuration.dart';
import '../network/coryn_api_request.dart';
import 'coryn_platform.dart';

/// Used on platforms without a native Coryn SDK (iOS, web, desktop): every call completes immediately and records nothing.
final class NoopCorynPlatform implements CorynPlatform {
  const NoopCorynPlatform();

  @override
  bool get isSupported => false;

  @override
  Future<CorynNativeStatus> attach(CorynPlatformListener listener) async => const CorynNativeStatus();

  @override
  Future<void> init(String apiKey, CorynConfiguration? configuration) async {}

  @override
  Future<void> startRecording(String? delayReason, CorynRecordingConfiguration? configuration) async {}

  @override
  Future<void> stopRecording(String? reason) async {}

  @override
  Future<int> registerScreen(String name, bool isDialog, Map<String, Object>? arguments) async => 0;

  @override
  Future<void> unregisterScreen(int handle) async {}

  @override
  Future<void> addEvent(String eventId, String? stateJson, int timePassedMs) async {}

  @override
  Future<void> addApiRequest(CorynApiRequest request) async {}

  @override
  Future<void> showToast(String text, bool isLong) async {}

  @override
  Future<void> setUserId(String? userId) async {}

  @override
  Future<void> sendScreenText(int requestId, List<List<Object>> items) async {}

  @override
  Future<void> sendTouch(int action, int actionPointer, List<num> pointers, int eventTimeMs) async {}

  @override
  Future<bool> sendStateBatch(Uint8List batch) async => true;

  @override
  Future<CorynFrameResult> sendFrame(Uint8List header, ByteData pixels) async => CorynFrameResult.rejected;

  @override
  Future<bool> sendUiUnchanged() async => true;

  @override
  Future<Map<String, Object?>> debugStats() async => const <String, Object?>{};

  @override
  Future<void> reportFailure(String reason, String? type, String? stacktrace) async {}
}
