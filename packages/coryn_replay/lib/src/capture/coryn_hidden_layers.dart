import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../configuration.dart';
import 'coryn_hide.dart';
import 'coryn_root.dart';

/// Hidden layers of the last frame below [root], mapped to their mask rectangles in each layer's coordinates.
///
/// * Every attached, enabled [RenderCorynHide] with a painted layer.
/// * With [CorynCaptureOptions.maskObscuredText], every `RenderEditable` with `obscureText`: it is not a repaint
///   boundary, so its text is painted into the layer of its nearest repaint-boundary ancestor, and that whole layer is
///   masked (possibly the whole root). Wrap password fields in `CorynHide` for a tight mask.
/// * Every active [SnapshotWidget] (the zoom page transition uses one), at its nearest enclosing repaint boundary.
///
/// Everything a hidden [CorynHide] shows in the Overlay through an `OverlayPortal` is masked at its nearest repaint
/// boundary too.
Map<Layer, Rect> collectHiddenLayers(RenderCorynRoot root, CorynCaptureOptions options) {
  final hidden = <Layer, Rect>{};
  for (final hide in RenderCorynHide.attachedHides) {
    final layer = hide.captureLayer;
    if (hide.hide && layer != null) hidden[layer] = hide.maskRect;
  }
  _collectElementMasks(root, hidden, options.maskObscuredText);
  return hidden;
}

/// One walk over the whole element tree finds snapshots, obscured text fields and content that a hidden [CorynHide]
/// shows elsewhere. No subtree is skipped: an `OverlayPortal` child is an element descendant of its portal but is
/// painted in the Overlay, outside every mask of the portal's ancestors (a hidden hide, an active snapshot).
///
/// A [SnapshotWidget] that draws its subtree from a cached image leaves an ordinary picture in the layer tree. The image
/// can hold pixels that are hidden or gone by now (content hidden after the image was taken, a forced snapshot, a
/// hidden widget or password field removed or moved since), so such a snapshot is masked at its nearest enclosing
/// repaint boundary, whatever it shows now (privacy over fidelity: a zoom page transition is recorded black while it
/// runs). Snapshots are found through their public widget type, which survives obfuscation. Every `RenderEditable` is
/// created by an element (`_Editable`), so the element walk also finds every obscured field.
///
/// Below a hidden [CorynHide], a render object whose render parent is not the render object of its nearest
/// render-object element ancestor was moved out of the hide's layer: an `OverlayPortal` child (tooltips, `MenuAnchor`
/// and `DropdownMenu` menus, `Autocomplete` options, slider value indicators) is a render child of the Overlay. It is
/// masked at its nearest repaint boundary, usually the whole Overlay, while it exists.
void _collectElementMasks(RenderCorynRoot root, Map<Layer, Rect> hidden, bool maskObscuredText) {
  final rootElement = WidgetsBinding.instance.rootElement;
  if (rootElement == null) return;
  RenderObject? parentRenderObject;
  var isInHiddenHide = false;
  void visit(Element element) {
    final outerParentRenderObject = parentRenderObject;
    final wasInHiddenHide = isInHiddenHide;
    if (element is RenderObjectElement) {
      final widget = element.widget;
      final renderObject = element.renderObject;
      final isMovedOutOfHide = isInHiddenHide && !identical(renderObject.parent, parentRenderObject);
      if (isMovedOutOfHide) _hideNearestBoundary(renderObject, root, hidden);
      if (widget is SnapshotWidget) {
        final isImageDrawn = widget.controller.allowSnapshotting || !_isChildPaintedLive(renderObject);
        if (isImageDrawn) _hideNearestBoundary(renderObject.parent, root, hidden);
      } else if (maskObscuredText && renderObject is RenderEditable && renderObject.obscureText) {
        _hideNearestBoundary(renderObject.parent, root, hidden);
      }
      if (renderObject is RenderCorynHide && renderObject.hide) isInHiddenHide = true;
      parentRenderObject = renderObject;
    }
    element.visitChildren(visit);
    parentRenderObject = outerParentRenderObject;
    isInHiddenHide = wasInHiddenHide;
  }

  rootElement.visitChildren(visit);
}

/// Masks the nearest repaint-boundary layer from [start] upwards (nothing before its first paint).
void _hideNearestBoundary(RenderObject? start, RenderCorynRoot root, Map<Layer, Rect> hidden) {
  RenderObject? current = start;
  while (current != null && !current.isRepaintBoundary) {
    current = current.parent;
  }
  final boundary = current ?? root;
  // ignore: invalid_use_of_protected_member
  final layer = identical(boundary, root) ? root.captureLayer : boundary.layer;
  if (layer == null) return;
  final maskRect = boundary is RenderCorynHide ? boundary.maskRect : boundary.paintBounds;
  hidden[layer] = maskRect;
}

/// Whether [snapshot] provably painted its child live in the last frame, judged from the layer tree rather than from
/// its controller, which the app may switch off after the frame was painted and before the capture: at least one of the
/// child's outermost repaint boundaries has an attached layer. While a snapshot draws its image, its child is not
/// painted into the tree, so those layers are detached. Anything else (no boundary, only detached or never painted
/// ones) is uncertain, because the cached image may hold a child that was replaced since, and the snapshot is masked.
bool _isChildPaintedLive(RenderObject snapshot) {
  var isAnyAttached = false;
  void visit(RenderObject object) {
    if (isAnyAttached) return;
    if (!object.isRepaintBoundary) {
      object.visitChildren(visit);
      return;
    }
    // ignore: invalid_use_of_protected_member
    if (object.layer?.attached ?? false) isAnyAttached = true;
  }

  snapshot.visitChildren(visit);
  return isAnyAttached;
}
