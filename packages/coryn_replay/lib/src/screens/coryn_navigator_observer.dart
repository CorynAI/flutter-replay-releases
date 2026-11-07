import 'package:flutter/widgets.dart';

import '../coryn.dart';
import 'coryn_screen_registration.dart';

/// Records the top-most page route of a [Navigator] as the current screen.
///
/// The screen is the top-most route that is a [PageRoute] (or that [screenName] names); dialogs and sheets above it stay
/// part of that screen. By default a page is recorded with its [RouteSettings.name]; an unnamed page records no screen.
/// Override [screenName] to name routes yourself (`null` records no screen). Route arguments are not recorded unless
/// [screenArguments] returns them, because they often contain private data.
///
/// Create one observer per Navigator and keep it for the Navigator's lifetime (a `State` field, not `build`): a new
/// observer does not learn the routes pushed before it. Call [dispose] when the Navigator goes away while the app keeps
/// running (for example a nested Navigator), because observers get no callback for that.
class CorynNavigatorObserver extends NavigatorObserver {
  CorynNavigatorObserver({String? Function(Route<dynamic> route)? screenName, this.screenArguments})
    : screenName = screenName ?? defaultScreenName;

  /// Name of [route], or `null` to record no screen for it.
  final String? Function(Route<dynamic> route) screenName;

  /// Optional `String`/`num`/`bool` arguments recorded with the screen.
  final Map<String, Object>? Function(Route<dynamic> route)? screenArguments;

  /// Every route of the navigator, bottom to top.
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];
  Route<dynamic>? _current;
  CorynScreenRegistration? _registration;

  /// Default naming: the name of a [PageRoute].
  static String? defaultScreenName(Route<dynamic> route) => route is PageRoute ? route.settings.name : null;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _update();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (newRoute == null) {
      if (index >= 0) _routes.removeAt(index);
    } else if (index >= 0) {
      _routes[index] = newRoute;
    } else {
      _routes.add(newRoute);
    }
    _update();
  }

  /// Ends the current screen and forgets the routes. Safe to call more than once.
  void dispose() {
    _registration?.unregister();
    _registration = null;
    _current = null;
    _routes.clear();
  }

  void _update() {
    final screen = _topScreenRoute();
    if (identical(screen, _current)) return;
    _registration?.unregister();
    _registration = null;
    _current = screen;
    if (screen == null) return;
    final name = screenName(screen);
    if (name == null) return;
    _registration = Coryn.registerScreen(name, arguments: screenArguments?.call(screen));
  }

  Route<dynamic>? _topScreenRoute() {
    for (final route in _routes.reversed) {
      final isScreen = route is PageRoute || screenName(route) != null;
      if (isScreen) return route;
    }
    return null;
  }
}
