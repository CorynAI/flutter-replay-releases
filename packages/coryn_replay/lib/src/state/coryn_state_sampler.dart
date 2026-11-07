import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'coryn_state.dart';
import 'coryn_state_batch.dart';

/// Receives encoded state batches.
abstract interface class CorynStateBatchSink {
  /// Completes with `true` once native applied the batch.
  Future<bool> sendStateBatch(Uint8List batch);
}

/// Pending operation of one key, coalesced until the next batch is sent.
sealed class _Operation {
  const _Operation();
}

final class _ValueOperation extends _Operation {
  const _ValueOperation(this.state);

  final CorynState state;
}

final class _MissingOperation extends _Operation {
  const _MissingOperation();
}

final class _FailureOperation extends _Operation {
  const _FailureOperation(this.message);

  final String message;
}

final class _RemoveOperation extends _Operation {
  const _RemoveOperation();
}

/// Marks a sample baseline that never equals a real state, so the next sample is sent again.
final class _Unsent {
  const _Unsent();
}

/// Baseline after `getState` failed; the same failure is not sent again.
final class _Failed {
  const _Failed(this.message);

  final String message;
}

enum _WriteResult { written, unchanged, full }

final class _ProviderEntry {
  _ProviderEntry(this.provider);

  final CorynStateProvider<CorynState> provider;

  /// Last sampled value: a [CorynState], `null`, [_Unsent] or [_Failed].
  Object? baseline = const _Unsent();
  bool isFailureReported = false;

  /// Consecutive `getState` failures and the earliest next read, like the native provider failure tracker.
  int failureCount = 0;
  Duration nextReadAt = Duration.zero;
}

/// Samples Dart state providers on the UI isolate and sends only changes to the native provider cache.
///
/// Sampling runs every 100 ms while the app is visible and every second while it is paused. Native samples user
///   providers every 100 ms for 30 s after the app left the screen and then only its own default states, so a change in
///   the background reaches native within a second and is recorded during that grace; later ones only refresh the
///   native cache that native samples again on resume.
/// * At most one batch is in flight. Until native acknowledges it, later samples are coalesced to the latest operation
///   per key and encoded only when the next batch is sent. A failed batch makes its keys resend.
/// `getState`/`toJson` failures and oversized JSON become failure operations, which the native proxy rethrows so the
///   SDK's provider failure tracking (backoff, integration errors) applies. A failing provider is itself read again only
///   after 1, 5, 15, 30 and then every 60 seconds, the native backoff.
/// A batch carries at most [maxBatchBytes] of state JSON; the rest stays coalesced for the next batch.
/// After [stop] (terminal, like the native `stopRecording`) nothing is sampled or registered again.
final class CorynStateSampler {
  CorynStateSampler(this._sink);

  /// Native limit of a state's JSON (`CorynState.toJsonString`), in UTF-16 characters.
  static const int maxJsonCharacters = 204800;
  static const Duration interval = Duration(milliseconds: 100);
  static const Duration pausedInterval = Duration(seconds: 1);
  static const int maxBatchBytes = 2 * 1024 * 1024;

  /// Longest state id in UTF-8 bytes. With JSON limited to 204,800 characters, one operation always fits a batch.
  static const int maxStateIdBytes = 1024;
  static const List<Duration> failureBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  final CorynStateBatchSink _sink;
  final Map<String, _ProviderEntry> _entries = <String, _ProviderEntry>{};
  final Map<String, _Operation> _pending = <String, _Operation>{};

  /// JSON of each key as native last applied it. A state that differs by `==` (for example a class without `==`) but
  /// encodes to the same JSON is not sent again: native would treat it as unchanged.
  final Map<String, Uint8List> _nativeJson = <String, Uint8List>{};
  final JsonUtf8Encoder _encoder = JsonUtf8Encoder();
  final Stopwatch _clock = Stopwatch()..start();

  /// Current time for failure backoff; tests replace it.
  @visibleForTesting
  late Duration Function() now = () => _clock.elapsed;
  Timer? _timer;
  bool _isPaused = false;
  bool _isRecording = false;
  bool _isInFlight = false;
  bool _isStopped = false;

  int get providerCount => _entries.length;

  /// Batches sent, for benchmarks.
  int get sentBatchCount => _sentBatchCount;
  int _sentBatchCount = 0;

  /// Operations sent, for benchmarks.
  int get sentOperationCount => _sentOperationCount;
  int _sentOperationCount = 0;

  /// Encoded bytes sent, for benchmarks.
  int get sentBytes => _sentBytes;
  int _sentBytes = 0;

  /// Time spent in [tick], for benchmarks.
  Duration get sampleTime => _sampleTime;
  Duration _sampleTime = Duration.zero;

  /// Time spent encoding batches, for benchmarks.
  Duration get encodeTime => _encodeTime;
  Duration _encodeTime = Duration.zero;

  /// Registers [provider] for [stateId], replacing (and notifying) a previous provider. Registering the same provider
  /// again changes nothing, like native. A replacement keeps the last sampled state as its baseline: native has one
  /// provider per id, so an equal state from the new provider is not sent again.
  void provide(String stateId, CorynStateProvider<CorynState> provider) {
    final isIdTooLong = utf8.encode(stateId).length > maxStateIdBytes;
    if (isIdTooLong) throw ArgumentError.value(stateId, 'stateId', 'Longer than $maxStateIdBytes UTF-8 bytes');
    if (_isStopped) {
      _notifyRemoved(stateId, provider);
      return;
    }
    final previous = _entries[stateId];
    if (previous != null && identical(previous.provider, provider)) return;
    final entry = _ProviderEntry(provider);
    final baseline = previous?.baseline;
    final isSampled = previous != null && baseline is! _Unsent && baseline is! _Failed;
    if (isSampled) entry.baseline = baseline;
    _entries[stateId] = entry;
    if (_pending[stateId] is _RemoveOperation) _pending.remove(stateId);
    if (previous != null) _notifyIfUnregistered(stateId, previous.provider);
    _schedule();
  }

  /// Removes the provider of [stateId]; its state ends on the timeline. With [expected], only while [expected] is still
  /// the registered provider (a newer registration of the id stays), like the native `expectedProvider`.
  void remove(String stateId, {CorynStateProvider<CorynState>? expected}) {
    final entry = _entries[stateId];
    if (entry == null) return;
    final isStaleRemoval = expected != null && !identical(entry.provider, expected);
    if (isStaleRemoval) return;
    _entries.remove(stateId);
    _pending[stateId] = const _RemoveOperation();
    _notifyIfUnregistered(stateId, entry.provider);
    _schedule();
  }

  /// Forgets every provider without sending removals (native already cleared them, or recording stopped). A provider
  /// registered under several ids is notified once.
  void clear() {
    final entries = Map<String, _ProviderEntry>.of(_entries);
    _entries.clear();
    _pending.clear();
    _cancel();
    final notified = Set<CorynStateProvider<CorynState>>.identity();
    for (final MapEntry<String, _ProviderEntry>(key: stateId, value: entry) in entries.entries) {
      if (notified.add(entry.provider)) _notifyRemoved(stateId, entry.provider);
    }
  }

  /// Recording stopped for good: forget every provider and what native acknowledged, and ignore later registrations.
  void stop() {
    _isStopped = true;
    _nativeJson.clear();
    clear();
  }

  /// States whose JSON native acknowledged, for tests.
  @visibleForTesting
  int get acknowledgedStateCount => _nativeJson.length;

  /// One provider instance may serve several ids; like native, it hears `onProviderRemove` only once no id holds it.
  void _notifyIfUnregistered(String stateId, CorynStateProvider<CorynState> provider) {
    final isRegistered = _entries.values.any((_ProviderEntry entry) => identical(entry.provider, provider));
    if (!isRegistered) _notifyRemoved(stateId, provider);
  }

  /// A throwing `onProviderRemove` must not break the caller (for example `stopRecording`).
  void _notifyRemoved(String stateId, CorynStateProvider<CorynState> provider) {
    try {
      provider.onProviderRemove();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'coryn_replay',
          context: ErrorDescription('in onProviderRemove of Coryn state "$stateId"'),
          silent: kReleaseMode,
        ),
      );
    }
  }

  /// Samples every [pausedInterval] while the app is paused.
  set isPaused(bool value) {
    if (_isPaused == value) return;
    _isPaused = value;
    _cancel();
    _schedule();
  }

  /// Samples only while a native session records (native samples nothing otherwise).
  set isRecording(bool value) {
    if (_isRecording == value) return;
    _isRecording = value;
    _cancel();
    _schedule();
  }

  void _schedule() {
    final hasWork = _entries.isNotEmpty || _pending.isNotEmpty;
    final shouldRun = hasWork && _isRecording;
    if (!shouldRun) {
      _cancel();
      return;
    }
    _timer ??= Timer.periodic(_isPaused ? pausedInterval : interval, (_) => tick());
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Samples every provider once and sends the changes when no batch is in flight. Public for tests and benchmarks.
  void tick() {
    final stopwatch = Stopwatch()..start();
    final time = now();
    for (final MapEntry<String, _ProviderEntry>(key: stateId, value: entry) in _entries.entries) {
      if (time < entry.nextReadAt) continue;
      _sample(stateId, entry, time);
    }
    _sampleTime += stopwatch.elapsed;
    _flush();
    if (_entries.isEmpty && _pending.isEmpty) _cancel();
  }

  void _sample(String stateId, _ProviderEntry entry, Duration now) {
    final CorynState? state;
    try {
      state = entry.provider.getState();
    } catch (error, stack) {
      final backoff = failureBackoff[math.min(entry.failureCount, failureBackoff.length - 1)];
      entry.failureCount++;
      entry.nextReadAt = now + backoff;
      _markFailed(stateId, entry, 'getState threw ${error.runtimeType}', error, stack);
      return;
    }
    entry.failureCount = 0;
    final baseline = entry.baseline;
    final isComparable = baseline is! _Unsent && baseline is! _Failed;
    final isUnchanged = identical(state, baseline) || (isComparable && state == baseline);
    if (isUnchanged) return;
    entry.baseline = state;
    _pending[stateId] = state == null ? const _MissingOperation() : _ValueOperation(state);
  }

  void _markFailed(String stateId, _ProviderEntry entry, String message, Object error, StackTrace stack) {
    final baseline = entry.baseline;
    final isSameFailure = baseline is _Failed && baseline.message == message;
    if (isSameFailure) return;
    entry.baseline = _Failed(message);
    _pending[stateId] = _FailureOperation(message);
    _report(stateId, entry, message, error, stack);
  }

  void _report(String stateId, _ProviderEntry entry, String message, Object? error, StackTrace? stack) {
    if (entry.isFailureReported) return;
    entry.isFailureReported = true;
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error ?? StateError(message),
        stack: stack,
        library: 'coryn_replay',
        context: ErrorDescription('while sampling Coryn state "$stateId"'),
        silent: kReleaseMode,
      ),
    );
  }

  void _flush() {
    if (_isInFlight || _pending.isEmpty) return;
    final stopwatch = Stopwatch()..start();
    final writer = CorynStateBatchWriter();
    final sent = <String, _Operation>{};
    final sentJson = <String, Uint8List>{};
    for (final stateId in _pending.keys.toList(growable: false)) {
      final operation = _pending[stateId]!;
      final result = _write(writer, stateId, operation, sentJson);
      if (result == _WriteResult.full) break;
      _pending.remove(stateId);
      if (result == _WriteResult.written) sent[stateId] = operation;
    }
    _encodeTime += stopwatch.elapsed;
    if (writer.isEmpty) return;
    final batch = writer.build();
    _isInFlight = true;
    _sentBatchCount++;
    _sentOperationCount += sent.length;
    _sentBytes += batch.length;
    _sink
        .sendStateBatch(batch)
        .then(
          (bool isApplied) => _onSent(sent, sentJson, isApplied),
          onError: (Object _) => _onSent(sent, sentJson, false),
        );
  }

  /// Appends [operation] unless it would make a non-empty batch exceed [maxBatchBytes], or skips a put whose JSON
  /// native already has. One operation always fits an empty batch (a state's JSON is at most 204,800 characters).
  _WriteResult _write(
    CorynStateBatchWriter writer,
    String stateId,
    _Operation operation,
    Map<String, Uint8List> sentJson,
  ) {
    final keyBytes = utf8.encode(stateId).length;
    switch (operation) {
      case _ValueOperation(:final state):
        final (json, failure) = _encode(stateId, state);
        if (json != null) {
          final nativeJson = _nativeJson[stateId];
          if (nativeJson != null && listEquals(nativeJson, json)) return _WriteResult.unchanged;
          if (!_fits(writer, keyBytes, json.length)) return _WriteResult.full;
          writer.put(stateId, json);
          sentJson[stateId] = json;
        } else {
          final message = failure ?? 'toJson failed';
          if (!_fits(writer, keyBytes, utf8.encode(message).length)) return _WriteResult.full;
          writer.failure(stateId, message);
        }
      case _MissingOperation():
        if (!_fits(writer, keyBytes, null)) return _WriteResult.full;
        writer.missing(stateId);
      case _FailureOperation(:final message):
        if (!_fits(writer, keyBytes, utf8.encode(message).length)) return _WriteResult.full;
        writer.failure(stateId, message);
      case _RemoveOperation():
        if (!_fits(writer, keyBytes, null)) return _WriteResult.full;
        writer.remove(stateId);
    }
    return _WriteResult.written;
  }

  /// Whether an operation with a [keyBytes] key and an optional [payloadBytes] payload keeps the batch, header
  /// included, within [maxBatchBytes]. An empty batch takes any single operation, which is bounded by the id and JSON
  /// limits.
  static bool _fits(CorynStateBatchWriter writer, int keyBytes, int? payloadBytes) {
    if (writer.isEmpty) return true;
    final payload = payloadBytes == null ? 0 : 4 + payloadBytes;
    final operationBytes = 1 + 4 + keyBytes + payload;
    return CorynStateBatchWriter.headerSize + writer.length + operationBytes <= maxBatchBytes;
  }

  /// Returns the JSON, or a failure message when [state] has no usable JSON. The baseline stays [state], so an unchanged
  /// invalid state is not re-encoded every tick; native keeps the failure until a different state arrives.
  (Uint8List?, String?) _encode(String stateId, CorynState state) {
    final entry = _entries[stateId];
    try {
      final json = _encoder.convert(state.toJson()) as Uint8List;
      final isTooLarge = json.length > maxJsonCharacters && utf8.decode(json).length > maxJsonCharacters;
      if (!isTooLarge) return (json, null);
      const message = 'JSON exceeds $maxJsonCharacters characters';
      if (entry != null) _report(stateId, entry, message, null, null);
      return (null, message);
    } catch (error, stack) {
      final message = 'toJson failed: ${error.runtimeType}';
      if (entry != null) _report(stateId, entry, message, error, stack);
      return (null, message);
    }
  }

  void _onSent(Map<String, _Operation> sent, Map<String, Uint8List> sentJson, bool isApplied) {
    _isInFlight = false;
    if (_isStopped) return;
    if (isApplied) {
      for (final stateId in sent.keys) {
        final json = sentJson[stateId];
        if (json == null) {
          _nativeJson.remove(stateId);
        } else {
          _nativeJson[stateId] = json;
        }
      }
    } else {
      for (final MapEntry<String, _Operation>(key: stateId, value: operation) in sent.entries) {
        final entry = _entries[stateId];
        if (entry != null) {
          entry.baseline = const _Unsent();
        } else if (operation is _RemoveOperation) {
          _pending.putIfAbsent(stateId, () => operation);
        }
      }
    }
    _flush();
  }
}
