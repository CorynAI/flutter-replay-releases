import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Hides [child] from UI captures: it is recorded as a black rectangle covering its bounds plus [padding].
///
/// Masking happens before blur, magnifiers, image filters and shaders are applied, and everything [child] paints is
/// removed, including overflow outside its bounds. Clips apply to the black rectangle like they would to the content.
///
/// What [child] shows in the Overlay through an `OverlayPortal` (tooltips, `MenuAnchor` and `DropdownMenu` menus,
/// `Autocomplete` options) is masked too, at the Overlay's nearest repaint boundary: usually the whole screen is black
/// while it is shown.
///
/// Content painted by widgets outside this subtree is not hidden: put `CorynHide` inside a `Hero` (not around it), and
/// hide routes (dialogs, `DropdownButton` menus), overlay entries or custom painters that show the same data elsewhere.
///
/// Screen text inside it is never recorded. Touches inside it (including [padding]) are recorded only with
/// [allowTouchRecording]: otherwise a touch that starts in or moves into it is not recorded until it ends, so typing
/// on a custom PIN pad cannot be reconstructed.
class CorynHide extends SingleChildRenderObjectWidget {
  const CorynHide({
    super.key,
    this.hide = true,
    this.padding = EdgeInsets.zero,
    this.allowTouchRecording = false,
    required Widget super.child,
  });

  /// Whether hiding is enabled.
  final bool hide;

  /// Extra hidden area around [child], in logical pixels.
  final EdgeInsets padding;

  /// Whether touches inside the hidden area are recorded. Defaults to `false`.
  final bool allowTouchRecording;

  @override
  RenderCorynHide createRenderObject(BuildContext context) {
    return RenderCorynHide(hide: hide, padding: padding, allowTouchRecording: allowTouchRecording);
  }

  @override
  void updateRenderObject(BuildContext context, RenderCorynHide renderObject) {
    renderObject
      ..hide = hide
      ..padding = padding
      ..allowTouchRecording = allowTouchRecording;
  }
}

/// Render object of [CorynHide]. Always a repaint boundary, so everything its subtree paints lives in its own layer,
/// which the capture replaces with a black rectangle.
class RenderCorynHide extends RenderProxyBox {
  RenderCorynHide({required bool hide, required EdgeInsets padding, required bool allowTouchRecording})
    // ignore: prefer_initializing_formals
    : _hide = hide,
      // ignore: prefer_initializing_formals
      _padding = padding,
      // ignore: prefer_initializing_formals
      _allowTouchRecording = allowTouchRecording;

  /// Whether touches inside [maskRect] are recorded. A change schedules a frame, which updates the touch regions.
  bool get allowTouchRecording => _allowTouchRecording;
  bool _allowTouchRecording;
  set allowTouchRecording(bool value) {
    if (_allowTouchRecording == value) return;
    _allowTouchRecording = value;
    markNeedsPaint();
  }

  /// Whether this object currently blocks touch recording.
  bool get isTouchBlocking => hide && !allowTouchRecording;

  /// Attached render objects; the capture looks up their layers.
  static final Set<RenderCorynHide> attachedHides = <RenderCorynHide>{};

  bool get hide => _hide;
  bool _hide;
  set hide(bool value) {
    if (_hide == value) return;
    _hide = value;
    markNeedsPaint();
  }

  EdgeInsets get padding => _padding;
  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (_padding == value) return;
    _padding = value;
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;

  /// The layer holding everything this subtree painted in the last frame, or `null` before the first paint.
  ContainerLayer? get captureLayer => layer;

  /// Hidden area in this object's layer coordinates.
  Rect get maskRect => padding.inflateRect(paintBounds);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    attachedHides.add(this);
  }

  @override
  void detach() {
    attachedHides.remove(this);
    super.detach();
  }
}
