import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'coryn_hide.dart';
import 'coryn_root.dart';

/// Receives the touches Dart allows; Android `MotionEvent` action codes, pointers as flat `id, x, y` triples in
/// physical pixels of the view.
abstract interface class CorynTouchSink {
  bool get isRecording;

  void sendTouch(int action, int actionPointer, List<num> pointers, int eventTimeMs);
}

/// Decides which Flutter touches are recorded. Native never records touches on a FlutterView; it records what this
/// tracker sends.
///
/// A touch is not recorded inside any region where a [CorynHide] that blocks touches was shown on the current surface:
/// the screen can still show an older frame than the one Dart built (frames are rasterized and presented later), and
/// nothing tells when it stopped showing it, so regions are kept until the surface is discarded. A pointer that is ever
/// inside a region is suppressed until it ends; one already recorded ends at its last recorded position. Without proof
/// that every frame of the surface was seen ([isCovered]: `Coryn.init` before `runApp`, no other isolate on the
/// surface, no failed frame), the whole view is blocked until the surface is discarded. A new surface shows the last
/// rasterized frame again, so it starts with the regions of every frame not yet reported as rasterized.
final class CorynTouchTracker {
  CorynTouchTracker(this._sink);

  static const int maxRegions = 32;
  static const Duration moveInterval = Duration(milliseconds: 50);
  static const int _actionDown = 0;
  static const int _actionUp = 1;
  static const int _actionMove = 2;
  static const int _actionPointerDown = 5;
  static const int _actionPointerUp = 6;
  static const int _maxPointerId = 31;

  /// Frames kept while no timing report arrives; older ones are merged, never dropped.
  static const int _maxUnrasterizedFrames = 240;

  final CorynTouchSink _sink;
  final List<Rect> _regions = <Rect>[];
  List<Rect> _lastFrameRegions = const <Rect>[];

  /// Regions of the frames that may still be the last rasterized one, by the frame's begin time stamp.
  final List<(Duration, List<Rect>)> _unrasterizedFrames = <(Duration, List<Rect>)>[];
  final Map<int, _Pointer> _pointers = <int, _Pointer>{};
  Duration? _lastMoveAt;
  bool _isCovered = false;
  bool _hasFailed = false;

  /// Whether every frame of the current surface was tracked, so that touches outside the regions may be recorded.
  bool get isCovered => _isCovered && !_hasFailed;

  /// Coverage decided at attach; it cannot undo a tracking failure of the current surface.
  void grantCoverage(bool isCovered) => _isCovered = isCovered;

  /// A frame or event could not be tracked: nothing on this view is recorded until the surface is discarded.
  void markFailed() => _hasFailed = true;

  /// Regions in view coordinates, for tests.
  @visibleForTesting
  List<Rect> get regions => List<Rect>.unmodifiable(_regions);

  /// The surface was discarded; the next one is tracked from its first frame. It first shows the last rasterized frame
  /// again, which may be any frame not yet reported as rasterized, so their regions stay.
  void onSurfaceDiscarded() {
    _regions
      ..clear()
      ..addAll(_lastFrameRegions);
    for (final (_, regions) in _unrasterizedFrames) {
      _regions.addAll(regions);
    }
    _isCovered = true;
    _hasFailed = false;
  }

  /// Frames up to the newest reported one were rasterized: only that frame and newer ones can still be shown again.
  void onFrameTimings(List<ui.FrameTiming> timings) {
    if (timings.isEmpty) return;
    final rasterized = timings
        .map(
          (ui.FrameTiming timing) => Duration(microseconds: timing.timestampInMicroseconds(ui.FramePhase.vsyncStart)),
        )
        .reduce((Duration a, Duration b) => a > b ? a : b);
    final lastRasterized = _unrasterizedFrames.lastIndexWhere(((Duration, List<Rect>) frame) => frame.$1 <= rasterized);
    if (lastRasterized > 0) _unrasterizedFrames.removeRange(0, lastRasterized);
  }

  /// Called after every frame was composited, before pointer events of the next frame are dispatched. Regions are
  /// collected with or without a captured root: a frame without one can still show a blocking hide.
  void onFrame(RenderCorynRoot? root, Duration frameTimeStamp) {
    final frameRegions = _blockingRegions();
    _lastFrameRegions = frameRegions;
    _unrasterizedFrames.add((frameTimeStamp, frameRegions));
    if (_unrasterizedFrames.length > _maxUnrasterizedFrames) _mergeOldestFrames();
    var isExpanded = false;
    for (final region in frameRegions) {
      final isKnown = _regions.any((Rect known) => _contains(known, region));
      if (isKnown) continue;
      _regions.add(region);
      isExpanded = true;
    }
    if (_regions.length > maxRegions) {
      final union = _regions.reduce((Rect a, Rect b) => a.expandToInclude(b));
      _regions
        ..clear()
        ..add(union);
    }
    if (isExpanded && root != null) _suppressPointersInRegions(root.flutterView);
  }

  void handleEvent(PointerEvent event, RenderCorynRoot? root) {
    if (root == null || event.viewId != root.flutterView.viewId) return;
    switch (event) {
      case PointerDownEvent():
        _onDown(event, root.flutterView);
      case PointerMoveEvent():
        _onMove(event, root.flutterView);
      case PointerUpEvent() || PointerCancelEvent():
        _onEnd(event, root.flutterView);
      default:
        return;
    }
  }

  void _onDown(PointerDownEvent event, ui.FlutterView view) {
    final pointer = _Pointer(event.device, event.position);
    _pointers[event.pointer] = pointer;
    final isAllowed = _sink.isRecording && event.device <= _maxPointerId && !_isBlocked(event.position);
    if (!isAllowed) return;
    final isFirst = !_pointers.values.any((_Pointer other) => other.isExported);
    pointer.isExported = true;
    final action = isFirst ? _actionDown : _actionPointerDown;
    _send(action, pointer, view, event.timeStamp);
  }

  void _onMove(PointerMoveEvent event, ui.FlutterView view) {
    final pointer = _pointers[event.pointer];
    if (pointer == null || !pointer.isExported) return;
    if (_isBlocked(event.position)) {
      _end(pointer, view, event.timeStamp);
      return;
    }
    pointer.position = event.position;
    final lastMoveAt = _lastMoveAt;
    final isDue = lastMoveAt == null || event.timeStamp - lastMoveAt >= moveInterval;
    if (!isDue) return;
    _lastMoveAt = event.timeStamp;
    _send(_actionMove, pointer, view, event.timeStamp);
  }

  void _onEnd(PointerEvent event, ui.FlutterView view) {
    final pointer = _pointers.remove(event.pointer);
    if (pointer == null || !pointer.isExported) return;
    if (!_isBlocked(event.position)) pointer.position = event.position;
    _end(pointer, view, event.timeStamp);
  }

  /// Ends [pointer] at its last recorded position; it stays suppressed until it goes up.
  void _end(_Pointer pointer, ui.FlutterView view, Duration timeStamp) {
    final others = _pointers.values.where((_Pointer other) => other.isExported && !identical(other, pointer));
    final action = others.isEmpty ? _actionUp : _actionPointerUp;
    _send(action, pointer, view, timeStamp);
    pointer.isExported = false;
  }

  void _suppressPointersInRegions(ui.FlutterView view) {
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    for (final pointer in _pointers.values.toList()) {
      if (pointer.isExported && _isBlocked(pointer.position)) _end(pointer, view, now);
    }
  }

  /// Merges the older half into one entry dated like its newest frame, so it stays until a newer frame is rasterized.
  void _mergeOldestFrames() {
    final count = _unrasterizedFrames.length ~/ 2;
    final merged = _unrasterizedFrames.take(count).expand(((Duration, List<Rect>) frame) => frame.$2).toList();
    final union = merged.isEmpty ? const <Rect>[] : <Rect>[merged.reduce((Rect a, Rect b) => a.expandToInclude(b))];
    final newest = _unrasterizedFrames[count - 1].$1;
    _unrasterizedFrames
      ..removeRange(0, count)
      ..insert(0, (newest, union));
  }

  /// Sends [action] of [actor] with every recorded pointer that is down, [actor] included.
  void _send(int action, _Pointer actor, ui.FlutterView view, Duration timeStamp) {
    if (!_sink.isRecording) return;
    final ratio = view.devicePixelRatio;
    final pointers = <num>[];
    final included = <_Pointer>{..._pointers.values.where((_Pointer pointer) => pointer.isExported), actor};
    for (final pointer in included) {
      pointers
        ..add(pointer.id)
        ..add(pointer.position.dx * ratio)
        ..add(pointer.position.dy * ratio);
    }
    _sink.sendTouch(action, actor.id, pointers, timeStamp.inMilliseconds);
  }

  bool _isBlocked(Offset position) {
    if (!isCovered) return true;
    return _regions.any((Rect region) => region.contains(position)) ||
        _lastFrameRegions.any((Rect region) => region.contains(position));
  }

  /// Regions, in view coordinates, of every enabled [CorynHide] that blocks touches and of everything such a hide shows
  /// elsewhere through an `OverlayPortal` (at its nearest repaint boundary).
  static List<Rect> _blockingRegions() {
    final hides = RenderCorynHide.attachedHides.where((RenderCorynHide hide) => hide.isTouchBlocking).toList();
    if (hides.isEmpty) return const <Rect>[];
    final regions = <Rect>[];
    for (final hide in hides) {
      if (!hide.attached || !hide.hasSize) continue;
      regions.add(MatrixUtils.transformRect(hide.getTransformTo(null), hide.maskRect));
    }
    _addMovedOutRegions(regions);
    return regions;
  }

  /// Render objects below a blocking hide in the element tree whose render parent is elsewhere were moved out of the
  /// hide's subtree (OverlayPortal); their nearest repaint boundary is blocked.
  static void _addMovedOutRegions(List<Rect> regions) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return;
    RenderObject? parentRenderObject;
    var isInBlockingHide = false;
    void visit(Element element) {
      final outerParent = parentRenderObject;
      final wasInBlockingHide = isInBlockingHide;
      if (element is RenderObjectElement) {
        final renderObject = element.renderObject;
        final isMovedOut = isInBlockingHide && !identical(renderObject.parent, parentRenderObject);
        if (isMovedOut) _addBoundaryRegion(renderObject, regions);
        if (renderObject is RenderCorynHide && renderObject.isTouchBlocking) isInBlockingHide = true;
        parentRenderObject = renderObject;
      }
      element.visitChildren(visit);
      parentRenderObject = outerParent;
      isInBlockingHide = wasInBlockingHide;
    }

    rootElement.visitChildren(visit);
  }

  static void _addBoundaryRegion(RenderObject start, List<Rect> regions) {
    RenderObject? current = start;
    while (current != null && !current.isRepaintBoundary) {
      current = current.parent;
    }
    final boundary = current ?? start;
    if (!boundary.attached) return;
    regions.add(MatrixUtils.transformRect(boundary.getTransformTo(null), boundary.paintBounds));
  }

  static bool _contains(Rect outer, Rect inner) {
    return inner.left >= outer.left &&
        inner.top >= outer.top &&
        inner.right <= outer.right &&
        inner.bottom <= outer.bottom;
  }
}

final class _Pointer {
  _Pointer(this.id, this.position);

  final int id;
  Offset position;
  bool isExported = false;
}
