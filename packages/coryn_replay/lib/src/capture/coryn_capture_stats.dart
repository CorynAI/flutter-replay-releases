import '../platform/coryn_platform.dart';

/// Timing and outcome counters of Dart UI captures, for tests and benchmarks.
final class CorynCaptureStats {
  int accepted = 0;
  int busy = 0;
  int rejected = 0;
  int rejectedCaptures = 0;
  int unchangedTicks = 0;
  int lastHiddenLayers = 0;
  int lastBytes = 0;

  /// UI-thread time to collect hidden layers, rebuild the scene and start rasterization.
  Duration totalWalk = Duration.zero;
  Duration maxWalk = Duration.zero;

  /// Rasterization and GPU-to-CPU read-back (asynchronous, off the UI thread).
  Duration totalReadback = Duration.zero;

  /// UI-thread time to copy pixels into the frame message.
  Duration totalEncode = Duration.zero;

  /// Channel round trip including native copy and composition.
  Duration totalSend = Duration.zero;
  Duration totalCapture = Duration.zero;
  Duration maxCapture = Duration.zero;

  int get frames => accepted + busy + rejected;

  void record({
    required CorynFrameResult result,
    required int hiddenLayers,
    required int bytes,
    required Duration walk,
    required Duration readback,
    required Duration encode,
    required Duration send,
    required Duration total,
  }) {
    switch (result) {
      case CorynFrameResult.accepted:
        accepted++;
      case CorynFrameResult.busy:
        busy++;
      case CorynFrameResult.rejected:
        rejected++;
    }
    lastHiddenLayers = hiddenLayers;
    lastBytes = bytes;
    totalWalk += walk;
    if (walk > maxWalk) maxWalk = walk;
    totalReadback += readback;
    totalEncode += encode;
    totalSend += send;
    totalCapture += total;
    if (total > maxCapture) maxCapture = total;
  }

  Map<String, Object> toMap() {
    double average(Duration total) => frames == 0 ? 0 : total.inMicroseconds / frames / 1000;
    return <String, Object>{
      'frames': frames,
      'accepted': accepted,
      'busy': busy,
      'rejected': rejected,
      'rejectedCaptures': rejectedCaptures,
      'unchangedTicks': unchangedTicks,
      'lastHiddenLayers': lastHiddenLayers,
      'lastBytes': lastBytes,
      'avgWalkMs': average(totalWalk),
      'maxWalkMs': maxWalk.inMicroseconds / 1000,
      'avgReadbackMs': average(totalReadback),
      'avgEncodeMs': average(totalEncode),
      'avgSendMs': average(totalSend),
      'avgCaptureMs': average(totalCapture),
      'maxCaptureMs': maxCapture.inMicroseconds / 1000,
    };
  }
}
