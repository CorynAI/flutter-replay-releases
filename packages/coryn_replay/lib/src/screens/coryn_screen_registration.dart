import 'dart:async';

import '../internal/coryn_runtime.dart';

/// A screen registered with `Coryn.registerScreen`. Call [unregister] when the screen goes away.
///
/// Native rejects screens before `Coryn.init`. A screen whose registration failed is registered once more after a
/// successful Dart `Coryn.init`, if it was not unregistered meanwhile, so a late init (for example after consent) still
/// records the screen the user is on.
final class CorynScreenRegistration {
  CorynScreenRegistration._(this.name, this._arguments, this._runtime);

  /// Registers [name] (no-op on unsupported platforms).
  static CorynScreenRegistration register(CorynRuntime runtime, String name, Map<String, Object>? arguments) {
    if (!runtime.platform.isSupported) return CorynScreenRegistration._(name, arguments, null);
    _checkArguments(arguments);
    final registration = CorynScreenRegistration._(name, arguments, runtime);
    registration._handle = registration._register(runtime);
    return registration;
  }

  final String name;
  final Map<String, Object>? _arguments;
  final CorynRuntime? _runtime;

  /// Native handle of the current registration attempt; `null` when nothing is registered.
  Future<int?> _handle = Future<int?>.value();
  bool _isUnregistered = false;

  bool get isUnregistered => _isUnregistered;

  Future<int?> _register(CorynRuntime runtime) async {
    try {
      if (!await runtime.ensureAttached()) return null;
      return await runtime.platform.registerScreen(name, _arguments);
    } catch (error) {
      runtime.logFailureOnce('registerScreen', error);
      runtime.registerAfterInit(this);
      return null;
    }
  }

  /// Called once after a successful Dart `Coryn.init` for a registration that failed before it.
  void retryAfterInit() {
    final runtime = _runtime;
    if (_isUnregistered || runtime == null) return;
    _handle = _register(runtime);
  }

  /// Ends the screen. Safe to call more than once.
  void unregister() {
    if (_isUnregistered) return;
    _isUnregistered = true;
    final runtime = _runtime;
    if (runtime == null) return;
    runtime.cancelAfterInit(this);
    unawaited(_unregister(runtime, _handle));
  }

  Future<void> _unregister(CorynRuntime runtime, Future<int?> registration) async {
    final handle = await registration;
    if (handle == null) return;
    try {
      await runtime.platform.unregisterScreen(handle);
    } catch (error) {
      runtime.logFailureOnce('unregisterScreen', error);
    }
  }

  static void _checkArguments(Map<String, Object>? arguments) {
    if (arguments == null) return;
    for (final MapEntry<String, Object>(:key, :value) in arguments.entries) {
      final isSupported = value is String || value is num || value is bool;
      if (!isSupported) throw ArgumentError.value(value, key, 'Screen arguments must be String, num or bool');
    }
  }
}
