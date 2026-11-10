import 'package:flutter/widgets.dart';

import '../coryn.dart';
import 'coryn_screen_registration.dart';

/// Records the top-most page, dialog or sheet route of a [Navigator] as the current screen.
///
/// The screen is the top-most route that is a [PageRoute], or that [screenName] names. By default pages and popup routes
/// ([PopupRoute]: dialogs, bottom sheets, menus) are named by their [RouteSettings.name], so a named dialog or sheet is a
/// screen of its own, recorded with `isDialog: true`, and the page below becomes the screen again when it closes. An
/// unnamed popup route records no screen and leaves the page below as the screen; an unnamed page records no screen.
/// Override [screenName] to name routes yourself (`null` records no screen). Route arguments are not recorded unless
/// [screenArguments] returns them, because they often contain private data. The name and arguments are read when a route
/// becomes the screen: a reused `Page` updated in place keeps them (give it a new key, or use `CorynScreen`).
///
/// Create one observer per Navigator and keep it for the Navigator's lifetime (a `State` field, not `build`): a new
/// observer does not learn the routes pushed before it. Call [dispose] when the Navigator goes away while the app keeps
/// running (for example a nested Navigator), because observers get no callback for that.
///
/// With `Navigator.pages`, observers hear no callback for pages reordered below an unchanged top route. Removing or
/// replacing a lower page imperatively (`removeRoute`, `replace`) after such a reorder can then record a covered page.
class CorynNavigatorObserver extends NavigatorObserver {
  CorynNavigatorObserver({String? Function(Route<dynamic> route)? screenName, this.screenArguments})
    : screenName = screenName ?? defaultScreenName;

  /// Name of [route], or `null` to record no screen for it.
  final String? Function(Route<dynamic> route) screenName;

  /// Optional `String`/`num`/`bool` arguments recorded with the screen.
  final Map<String, Object>? Function(Route<dynamic> route)? screenArguments;

  /// Every route of the navigator, bottom to top.
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];

  /// The registered screens, bottom to top: the top-most page and the named popups above it.
  final List<(Route<dynamic>, CorynScreenRegistration?)> _screens = <(Route<dynamic>, CorynScreenRegistration?)>[];

  /// Default naming: the name of a [PageRoute] or a [PopupRoute].
  static String? defaultScreenName(Route<dynamic> route) {
    final isNamedByDefault = route is PageRoute || route is PopupRoute;
    return isNamedByDefault ? route.settings.name : null;
  }

  /// A declarative `Navigator.pages` update can add a page below the top one; no [previousRoute] means at the bottom.
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final previousIndex = previousRoute == null ? -1 : _routes.indexOf(previousRoute);
    final isUnknownPrevious = previousRoute != null && previousIndex < 0;
    if (isUnknownPrevious) {
      _routes.add(route);
    } else {
      _routes.insert(previousIndex + 1, route);
    }
    _update();
  }

  /// A `Navigator.pages` update can reorder existing routes without pushing or popping them. Flutter keeps the pageless
  /// routes (dialogs, pushed routes) of a page after it, so the new top's page moves to the top with them. When it
  /// reassembles the history, Flutter reverses the pageless routes of the top page: the new top is then the lowest of
  /// them (removals are reported before this callback, so a pop never leaves the top below other routes).
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    final topIndex = _routes.indexOf(topRoute);
    if (topIndex < 0) return;
    var start = topIndex;
    while (start > 0 && !_isPage(_routes[start])) {
      start--;
    }
    var end = topIndex + 1;
    while (end < _routes.length && !_isPage(_routes[end])) {
      end++;
    }
    final group = _routes.sublist(start, end);
    _routes.removeRange(start, end);
    final pagelessStart = _isPage(group.first) ? 1 : 0;
    final isReversed = group.length - pagelessStart > 1 && identical(group[pagelessStart], topRoute);
    final pageless = group.sublist(pagelessStart);
    _routes
      ..addAll(group.sublist(0, pagelessStart))
      ..addAll(isReversed ? pageless.reversed : pageless);
    _update();
  }

  static bool _isPage(Route<dynamic> route) => route.settings is Page<Object?>;

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
    _unregisterFrom(0);
    _routes.clear();
  }

  /// A named popup is registered above the page and popups below it, which stay registered: when it closes, native
  /// returns to the newest screen still registered, which may be a nested Navigator's page or a `CorynScreen` inside
  /// the screen below. Screens that stay are not registered again; a change below them registers them again above it.
  void _update() {
    final routes = _screenRoutes();
    var kept = 0;
    while (kept < _screens.length && kept < routes.length && identical(_screens[kept].$1, routes[kept])) {
      kept++;
    }
    _unregisterFrom(kept);
    for (final route in routes.skip(kept)) {
      _screens.add((route, _register(route)));
    }
  }

  void _unregisterFrom(int index) {
    for (var i = _screens.length - 1; i >= index; i--) {
      _screens[i].$2?.unregister();
    }
    _screens.removeRange(index, _screens.length);
  }

  CorynScreenRegistration? _register(Route<dynamic> route) {
    final name = screenName(route);
    if (name == null) return null;
    return Coryn.registerScreen(name, isDialog: route is PopupRoute, arguments: screenArguments?.call(route));
  }

  /// The top-most screen route that is not a popup and the named popups above it, bottom to top.
  List<Route<dynamic>> _screenRoutes() {
    final popups = <Route<dynamic>>[];
    for (final route in _routes.reversed) {
      final isScreen = route is PageRoute || screenName(route) != null;
      if (!isScreen) continue;
      if (route is! PopupRoute) return <Route<dynamic>>[route, ...popups.reversed];
      popups.add(route);
    }
    return popups.reversed.toList();
  }
}
