import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'coryn_hide.dart';
import 'coryn_root.dart';

/// Reads the text the user can see inside the captured root, for native screen text. Only text that is provably shown
/// in full is read; anything uncertain is left out:
///
/// Text below an enabled [CorynHide] (also what it shows elsewhere through an `OverlayPortal`) and every `obscureText`
/// field are never read. A text object is read only when its whole text is laid out inside its own size (nothing
/// ellipsized, truncated or scrolled away) and its bounds lie inside every ancestor clip and the root. Text below a
/// path or oval clip, a custom clipper, a shader mask, a backdrop, color or image filter, an opacity that paints
/// nothing, a singular transform, an offstage or unpainted subtree (also above the root) or an image-drawing
/// [SnapshotWidget], and text with a span whose 8-bit alpha is zero, is left out. Text covered by other widgets is
/// read: overlap is not tracked.
final class CorynScreenTextReader {
  static const int maxTexts = 4096;
  static const int maxCharacters = 16384;

  /// Elements visited per sample; the rest of a larger tree is not read.
  static const int maxNodes = 8192;

  /// Spans and characters inspected per sample, read or not; texts after the budget is spent are not read.
  static const int maxSpans = 8192;
  static const int maxInspectedCharacters = 4 * maxCharacters;

  /// Allowed overlap of rounding errors when comparing rectangles, in logical pixels.
  static const double _epsilon = 0.5;

  final Expando<int> _ids = Expando<int>('coryn screen text');
  int _nextId = 0;
  RenderCorynRoot? _sampledRoot;
  int? _sampledFrame;
  List<List<Object>> _sample = const <List<Object>>[];

  /// `[id, text]` pairs in drawing order. The previous sample is reused while no frame was drawn since it.
  List<List<Object>> read(RenderCorynRoot root, int frameCount) {
    final isSameFrame = identical(root, _sampledRoot) && frameCount == _sampledFrame;
    if (isSameFrame) return _sample;
    _sample = _readTexts(root);
    _sampledRoot = root;
    _sampledFrame = frameCount;
    return _sample;
  }

  /// Forgets the last sample, after a stop or a selection change.
  void clear() {
    _sampledRoot = null;
    _sampledFrame = null;
    _sample = const <List<Object>>[];
  }

  List<List<Object>> _readTexts(RenderCorynRoot root) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null || !root.attached || !root.hasSize) return const <List<Object>>[];
    final texts = <List<Object>>[];
    final budget = _Budget();
    var remainingCharacters = maxCharacters;
    // Element.visitChildren cannot stop early: once a budget is spent, each remaining sibling returns at once.
    void visit(Element element, bool isExcluded) {
      if (texts.length >= maxTexts || remainingCharacters <= 0 || budget.isSpent) return;
      budget.nodes--;
      var isChildExcluded = isExcluded || _isSnapshotDrawing(element);
      if (element is RenderObjectElement) {
        final renderObject = element.renderObject;
        if (renderObject is RenderCorynHide && renderObject.hide) isChildExcluded = true;
        if (!isChildExcluded && renderObject is RenderBox) {
          final text = _readVisibleText(renderObject, root, budget);
          if (text != null) {
            final bounded = text.length > remainingCharacters ? text.substring(0, remainingCharacters) : text;
            remainingCharacters -= bounded.length;
            texts.add(<Object>[_idOf(renderObject), bounded]);
          }
        }
      }
      element.visitChildren((Element child) => visit(child, isChildExcluded));
    }

    rootElement.visitChildren((Element child) => visit(child, false));
    return texts;
  }

  /// Content drawn from a cached image or through a color or image filter, which can erase or garble it, is not read.
  static bool _isSnapshotDrawing(Element element) {
    final widget = element.widget;
    if (widget is ColorFiltered || widget is ImageFiltered) return true;
    return widget is SnapshotWidget && widget.controller.allowSnapshotting;
  }

  int _idOf(RenderObject renderObject) => _ids[renderObject] ??= _nextId++;

  /// Cheap checks and geometry come first; the text is flattened only for a visible, bounded candidate.
  static String? _readVisibleText(RenderBox box, RenderCorynRoot root, _Budget budget) {
    final isCandidate = switch (box) {
      RenderParagraph() => !box.didExceedMaxLines,
      RenderEditable() => !box.obscureText,
      _ => false,
    };
    if (!isCandidate || !box.attached || !box.hasSize || !_isShownInFull(box, root)) return null;
    final String? text = switch (box) {
      RenderParagraph() => _readParagraph(box, budget),
      RenderEditable() => _readEditable(box, budget),
      _ => null,
    };
    if (text == null || text.trim().isEmpty) return null;
    return text;
  }

  static String? _readParagraph(RenderParagraph paragraph, _Budget budget) {
    if (!_isFlattenable(paragraph.text, budget)) return null;
    final text = paragraph.text.toPlainText(includeSemanticsLabels: false);
    final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length));
    if (!_areBoxesInside(boxes, paragraph.size)) return null;
    return _withoutPlaceholders(text);
  }

  static String? _readEditable(RenderEditable editable, _Budget budget) {
    final span = editable.text;
    if (span == null || !_isFlattenable(span, budget)) return null;
    final text = span.toPlainText(includeSemanticsLabels: false);
    final boxes = editable.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length));
    if (!_areBoxesInside(boxes, editable.size)) return null;
    return _withoutPlaceholders(text);
  }

  static String _withoutPlaceholders(String text) => text.replaceAll('\uFFFC', ' ');

  static bool _areBoxesInside(List<TextBox> boxes, Size size) {
    final bounds = (Offset.zero & size).inflate(_epsilon);
    for (final box in boxes) {
      final rect = box.toRect();
      if (!_contains(bounds, rect)) return false;
    }
    return true;
  }

  /// A text is read only when no span paints its glyphs invisibly (a zero 8-bit alpha, or a foreground paint with a
  /// blend mode, filter, shader or mask whose result is unknown) and it fits in what is left of the sample's span and
  /// character budget, which every inspected span is charged to before anything is flattened.
  static bool _isFlattenable(InlineSpan root, _Budget budget) {
    var isRejected = false;
    void visit(InlineSpan span, Color? inheritedColor, Paint? inheritedForeground) {
      if (isRejected) return;
      budget.spans--;
      final foreground = span.style?.foreground ?? inheritedForeground;
      final color = foreground?.color ?? span.style?.color ?? inheritedColor;
      final text = span is TextSpan ? span.text ?? '' : '';
      budget.characters -= text.length;
      final isTransparent = color != null && Color.getAlphaFromOpacity(color.a) == 0;
      final isInvisible = text.isNotEmpty && (isTransparent || (foreground != null && !_isPlainPaint(foreground)));
      if (isInvisible || budget.spans < 0 || budget.characters < 0) {
        isRejected = true;
        return;
      }
      span.visitDirectChildren((InlineSpan child) {
        visit(child, color, foreground);
        return !isRejected;
      });
    }

    visit(root, null, null);
    return !isRejected;
  }

  static bool _isPlainPaint(Paint paint) {
    final hasEffect = paint.colorFilter != null || paint.shader != null || paint.maskFilter != null;
    return paint.blendMode == BlendMode.srcOver && !hasEffect && paint.imageFilter == null && !paint.invertColors;
  }

  /// Walks from [box] to the render view: every ancestor paints its child, with no unsupported effect, the box lies
  /// inside every ancestor clip (in that ancestor's coordinates) and inside [root], and no transform on the way is
  /// singular (Flutter paints nothing below one).
  static bool _isShownInFull(RenderBox box, RenderCorynRoot root) {
    final determinant = box.getTransformTo(null).determinant();
    if (!determinant.isFinite || determinant == 0) return false;
    final bounds = MatrixUtils.transformRect(box.getTransformTo(root), Offset.zero & box.size);
    final isPainted = bounds.isFinite && bounds.width > 0 && bounds.height > 0;
    if (!isPainted) return false;
    var isInsideRoot = false;
    RenderObject child = box;
    for (RenderObject? parent = box.parent; parent != null; parent = parent.parent) {
      if (!parent.paintsChild(child) || _isInvisibleParent(parent) || _isUnsupportedParent(parent)) return false;
      final clip = _clipOf(parent, child);
      if (clip != null) {
        final rect = MatrixUtils.transformRect(box.getTransformTo(parent), Offset.zero & box.size);
        if (!_contains(clip.inflate(_epsilon), rect)) return false;
      }
      if (identical(parent, root)) {
        final rect = MatrixUtils.transformRect(box.getTransformTo(root), Offset.zero & box.size);
        if (!_contains((Offset.zero & root.size).inflate(_epsilon), rect)) return false;
        isInsideRoot = true;
      }
      child = parent;
    }
    return isInsideRoot;
  }

  /// Opacity is compared after the engine's quantization to an 8-bit alpha, at which a small positive opacity paints
  /// nothing.
  static bool _isInvisibleParent(RenderObject parent) {
    return switch (parent) {
      RenderOffstage() => parent.offstage,
      RenderOpacity() => _isTransparent(parent.opacity),
      RenderAnimatedOpacity() => _isTransparent(parent.opacity.value),
      RenderSliverOpacity() => _isTransparent(parent.opacity),
      RenderSliverAnimatedOpacity() => _isTransparent(parent.opacity.value),
      _ => false,
    };
  }

  static bool _isTransparent(double opacity) => Color.getAlphaFromOpacity(opacity) == 0;

  static bool _isUnsupportedParent(RenderObject parent) {
    return switch (parent) {
      RenderClipPath() || RenderClipOval() || RenderShaderMask() || RenderBackdropFilter() => true,
      RenderClipRect() => parent.clipper != null,
      RenderClipRRect() => parent.clipper != null,
      _ => false,
    };
  }

  /// The clip [parent] applies to [child], in [parent]'s coordinates; a rounded rectangle is reduced to the rectangle
  /// inside its corners.
  static Rect? _clipOf(RenderObject parent, RenderObject child) {
    if (parent is RenderClipRRect && parent.clipBehavior != Clip.none) {
      final radius = parent.borderRadius.resolve(parent.textDirection);
      final largest = <double>[
        radius.topLeft.x,
        radius.topLeft.y,
        radius.topRight.x,
        radius.topRight.y,
        radius.bottomLeft.x,
        radius.bottomLeft.y,
        radius.bottomRight.x,
        radius.bottomRight.y,
      ].reduce((double a, double b) => a > b ? a : b);
      final inner = (Offset.zero & parent.size).deflate(largest);
      return inner.isEmpty ? Rect.zero : inner;
    }
    return parent.describeApproximatePaintClip(child);
  }

  static bool _contains(Rect outer, Rect inner) {
    return inner.left >= outer.left &&
        inner.top >= outer.top &&
        inner.right <= outer.right &&
        inner.bottom <= outer.bottom;
  }
}

final class _Budget {
  int nodes = CorynScreenTextReader.maxNodes;
  int spans = CorynScreenTextReader.maxSpans;
  int characters = CorynScreenTextReader.maxInspectedCharacters;

  bool get isSpent => nodes <= 0 || spans <= 0 || characters <= 0;
}
