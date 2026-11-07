import 'package:collection/collection.dart';

/// A recorded state snapshot.
///
/// Instances must be immutable: the SDK keeps returned snapshots and compares them with `==` to detect changes.
/// `==` must agree with [toJson]: two equal states must produce the same JSON, and states with different JSON must
/// not be equal. This is the same contract as the Android `CorynState`.
abstract interface class CorynState {
  /// JSON-encodable value (`Map`, `List`, `String`, `num`, `bool` or `null`) describing this state.
  ///
  /// Called only when the state changed. The encoded JSON may have at most 64 nesting levels and
  /// 204,800 characters; larger states are dropped and reported in debug builds.
  Object? toJson();
}

/// Supplies the current value of a state.
///
/// [getState] runs on the UI isolate at most every 100 ms while the app is visible (every second while it is in the
/// background), so it must be cheap and synchronous. Return the same instance while nothing changed: `identical` is
/// checked before `==`.
abstract interface class CorynStateProvider<S extends CorynState> {
  /// Current state, or `null` when the state is unavailable. Returning `null` ends the state on the timeline.
  ///
  /// Only read: [getState], and `toJson` and `==` of the returned states, must not register, replace or remove Coryn
  /// providers (`Coryn.provideState`, `Coryn.removeState`, `CorynStateScope` changes), directly or indirectly.
  S? getState();

  /// Called once after the provider was removed or replaced under every id it was registered with.
  void onProviderRemove();
}

/// A [CorynStateProvider] backed by a callback.
final class CorynCallbackStateProvider<S extends CorynState> implements CorynStateProvider<S> {
  CorynCallbackStateProvider(this._getState, {void Function()? onProviderRemove})
    // ignore: prefer_initializing_formals
    : _onProviderRemove = onProviderRemove;

  final S? Function() _getState;
  final void Function()? _onProviderRemove;

  @override
  S? getState() => _getState();

  @override
  void onProviderRemove() => _onProviderRemove?.call();
}

/// A [CorynState] holding a JSON-encodable value.
///
/// Equality compares the value deeply, which costs more than comparing purpose-built immutable classes. Prefer your
/// own immutable states with a cheap `==` for states read every tick.
final class CorynJsonState implements CorynState {
  /// [value] must not be modified after it is passed here.
  const CorynJsonState(this.value);

  final Object? value;

  static const DeepCollectionEquality _equality = DeepCollectionEquality();

  @override
  Object? toJson() => value;

  @override
  bool operator ==(Object other) => other is CorynJsonState && _equality.equals(value, other.value);

  @override
  int get hashCode => _equality.hash(value);

  @override
  String toString() => 'CorynJsonState($value)';
}
