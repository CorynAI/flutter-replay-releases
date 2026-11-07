import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../coryn.dart';
import 'coryn_state.dart';

/// Provides a state while this widget is mounted, like the Android `CorynStateProviderRoot`.
class CorynStateScope extends StatefulWidget {
  const CorynStateScope({super.key, required this.stateId, required this.provider, required this.child});

  final String stateId;
  final CorynStateProvider<CorynState> provider;
  final Widget child;

  @override
  State<CorynStateScope> createState() => _CorynStateScopeState();
}

class _CorynStateScopeState extends State<CorynStateScope> {
  @override
  void initState() {
    super.initState();
    Coryn.provideState(widget.stateId, widget.provider);
  }

  @override
  void didUpdateWidget(CorynStateScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    final isSame = oldWidget.stateId == widget.stateId && identical(oldWidget.provider, widget.provider);
    if (isSame) return;
    // The new id first: a provider kept under a new id is then never without a registration, so it is not disposed.
    Coryn.provideState(widget.stateId, widget.provider);
    if (oldWidget.stateId != widget.stateId) Coryn.removeState(oldWidget.stateId, provider: oldWidget.provider);
  }

  /// Another scope may have provided the same id since (for example the same page pushed again); its provider stays.
  @override
  void dispose() {
    Coryn.removeState(widget.stateId, provider: widget.provider);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A provider reading a [ValueListenable] and mapping its value to a [CorynState].
///
/// [toState] runs only when the value changes (by identity), so the sampler compares the cached state cheaply.
final class CorynValueListenableStateProvider<T> implements CorynStateProvider<CorynState> {
  CorynValueListenableStateProvider(this.listenable, this.toState);

  final ValueListenable<T> listenable;
  final CorynState? Function(T value) toState;
  Object? _lastValue = _none;
  CorynState? _lastState;

  static const Object _none = Object();

  /// A throwing [toState] caches nothing, so the next read (after the sampler's failure backoff) maps the value again.
  @override
  CorynState? getState() {
    final value = listenable.value;
    if (identical(value, _lastValue)) return _lastState;
    final state = toState(value);
    _lastValue = value;
    _lastState = state;
    return state;
  }

  @override
  void onProviderRemove() {}
}
