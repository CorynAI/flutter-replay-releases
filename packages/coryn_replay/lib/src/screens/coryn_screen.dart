import 'package:flutter/widgets.dart';

import '../coryn.dart';
import 'coryn_screen_registration.dart';

/// Records [name] as a screen while this widget is mounted. Use it for navigation that `CorynNavigatorObserver`
/// cannot see (tabs, custom routers).
class CorynScreen extends StatefulWidget {
  const CorynScreen({super.key, required this.name, this.arguments, required this.child});

  final String name;

  /// `String`/`num`/`bool` values recorded with the screen. Never pass private data.
  final Map<String, Object>? arguments;
  final Widget child;

  @override
  State<CorynScreen> createState() => _CorynScreenState();
}

class _CorynScreenState extends State<CorynScreen> {
  CorynScreenRegistration? _registration;

  @override
  void initState() {
    super.initState();
    _register();
  }

  @override
  void didUpdateWidget(CorynScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final isChanged = oldWidget.name != widget.name || !_sameArguments(oldWidget.arguments, widget.arguments);
    if (!isChanged) return;
    _registration?.unregister();
    _register();
  }

  void _register() {
    _registration = Coryn.registerScreen(widget.name, arguments: widget.arguments);
  }

  static bool _sameArguments(Map<String, Object>? a, Map<String, Object>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (final MapEntry<String, Object>(:key, :value) in a.entries) {
      if (b[key] != value) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _registration?.unregister();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
