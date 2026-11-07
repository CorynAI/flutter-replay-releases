import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

/// Outcome of [CorynSceneMasker.build].
sealed class CorynMaskedSceneResult {
  const CorynMaskedSceneResult();
}

/// A masked image of the root, ready for read-back. The caller owns [image].
final class CorynMaskedImage extends CorynMaskedSceneResult {
  const CorynMaskedImage(this.image);

  final ui.Image image;
}

/// The root has not painted yet; nothing to capture.
final class CorynMaskedSceneNotPainted extends CorynMaskedSceneResult {
  const CorynMaskedSceneNotPainted();
}

/// The frame cannot be captured without risking a leak (unsupported layer). This is a capture failure.
final class CorynMaskedSceneRejected extends CorynMaskedSceneResult {
  const CorynMaskedSceneRejected(this.reason);

  final String reason;
}

/// Rebuilds the last composited frame below a root layer into a new scene in which every hidden layer is replaced by a
/// black rectangle *before* any effect is applied.
///
/// * The walk only reads the framework layer tree, which changes only during a frame; it must run synchronously between
///   frames. Framework pictures are referenced, never disposed; masks are SDK-owned and disposed here.
/// * A hidden layer's subtree is never added, so no blur, magnifier ([BackdropFilterLayer] with a matrix filter),
///   [ImageFilterLayer] or shader can read or move hidden pixels: they can only see black. Privacy does not depend on
///   geometry: a wrong offset can only misplace a black box.
/// * [PlatformViewLayer] and [TextureLayer] become black: their content is sampled at raster time, not from this frame.
/// * Layers are dispatched by exact runtime type through public fields; an unknown layer type rejects the capture.
final class CorynSceneMasker {
  CorynSceneMasker(this._hidden);

  /// Hidden layers mapped to their mask rectangle in the layer's own coordinates.
  final Map<Layer, Rect> _hidden;
  final List<ui.Picture> _ownedPictures = <ui.Picture>[];
  final Map<BackdropKey, int> _backdropIds = <BackdropKey, int>{};
  static final Paint _black = Paint()..color = const Color(0xFF000000);
  String? _rejection;

  /// Builds a [width] x [height] image of [rootLayer]'s children at [pixelRatio] physical pixels per logical pixel.
  /// [rootLayer] is the root's own repaint-boundary layer, so its children are in root-local coordinates.
  CorynMaskedSceneResult build(OffsetLayer? rootLayer, double pixelRatio, int width, int height) {
    if (rootLayer == null || !rootLayer.attached) return const CorynMaskedSceneNotPainted();
    final builder = ui.SceneBuilder();
    builder.pushTransform(Matrix4.diagonal3Values(pixelRatio, pixelRatio, 1).storage);
    final rootMask = _hidden[rootLayer];
    if (rootMask != null) {
      _addBlack(builder, rootMask);
    } else {
      _addChildren(builder, rootLayer);
    }
    final rejection = _rejection;
    if (rejection != null) {
      _disposeOwned();
      return CorynMaskedSceneRejected(rejection);
    }
    builder.pop();
    final scene = builder.build();
    try {
      return CorynMaskedImage(scene.toImageSync(width, height));
    } finally {
      scene.dispose();
      _disposeOwned();
    }
  }

  void _disposeOwned() {
    for (final picture in _ownedPictures) {
      picture.dispose();
    }
    _ownedPictures.clear();
  }

  void _addChildren(ui.SceneBuilder builder, ContainerLayer container) {
    for (Layer? child = container.firstChild; child != null; child = child.nextSibling) {
      _addLayer(builder, child);
      if (_rejection != null) return;
    }
  }

  void _addLayer(ui.SceneBuilder builder, Layer layer) {
    final mask = _hidden[layer];
    if (mask != null) {
      _addMask(builder, layer, mask);
      return;
    }
    final type = layer.runtimeType;
    if (type == PictureLayer) return _addPicture(builder, layer as PictureLayer);
    if (type == OffsetLayer) return _addOffset(builder, layer as OffsetLayer);
    if (type == TransformLayer) return _addTransform(builder, layer as TransformLayer);
    if (type == OpacityLayer) return _addOpacity(builder, layer as OpacityLayer);
    if (type == ClipRectLayer) return _addClipRect(builder, layer as ClipRectLayer);
    if (type == ClipRRectLayer) return _addClipRRect(builder, layer as ClipRRectLayer);
    if (type == ClipRSuperellipseLayer) return _addClipRSuperellipse(builder, layer as ClipRSuperellipseLayer);
    if (type == ClipPathLayer) return _addClipPath(builder, layer as ClipPathLayer);
    if (type == ColorFilterLayer) return _addColorFilter(builder, layer as ColorFilterLayer);
    if (type == ImageFilterLayer) return _addImageFilter(builder, layer as ImageFilterLayer);
    if (type == ShaderMaskLayer) return _addShaderMask(builder, layer as ShaderMaskLayer);
    if (type == BackdropFilterLayer) return _addBackdropFilter(builder, layer as BackdropFilterLayer);
    if (type == LeaderLayer) return _addLeader(builder, layer as LeaderLayer);
    if (type == FollowerLayer) return _addFollower(builder, layer as FollowerLayer);
    if (type == TextureLayer) return _addBlack(builder, (layer as TextureLayer).rect);
    if (type == PlatformViewLayer) return _addBlack(builder, (layer as PlatformViewLayer).rect);
    if (type == PerformanceOverlayLayer) return;
    if (type == ContainerLayer || layer is AnnotatedRegionLayer) return _addChildren(builder, layer as ContainerLayer);
    _rejection = 'unsupported layer ${layer.runtimeType}';
  }

  void _addMask(ui.SceneBuilder builder, Layer layer, Rect mask) {
    if (layer is! OffsetLayer) return _addBlack(builder, mask);
    builder.pushOffset(layer.offset.dx, layer.offset.dy);
    _addBlack(builder, mask);
    builder.pop();
  }

  void _addBlack(ui.SceneBuilder builder, Rect rect) {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(rect, _black);
    final picture = recorder.endRecording();
    _ownedPictures.add(picture);
    builder.addPicture(Offset.zero, picture);
  }

  void _addPicture(ui.SceneBuilder builder, PictureLayer layer) {
    final picture = layer.picture;
    if (picture == null) return;
    builder.addPicture(Offset.zero, picture, isComplexHint: layer.isComplexHint, willChangeHint: layer.willChangeHint);
  }

  void _addOffset(ui.SceneBuilder builder, OffsetLayer layer) {
    builder.pushOffset(layer.offset.dx, layer.offset.dy);
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addTransform(ui.SceneBuilder builder, TransformLayer layer) {
    final transform = layer.transform;
    if (transform == null) {
      _rejection = 'TransformLayer without transform';
      return;
    }
    final offset = layer.offset;
    final effective = offset == Offset.zero
        ? transform
        : (Matrix4.translationValues(offset.dx, offset.dy, 0)..multiply(transform));
    builder.pushTransform(effective.storage);
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addOpacity(ui.SceneBuilder builder, OpacityLayer layer) {
    if (layer.firstChild == null) return;
    final alpha = layer.alpha;
    if (alpha == null) {
      _rejection = 'OpacityLayer without alpha';
      return;
    }
    if (alpha < 255) {
      builder.pushOpacity(alpha, offset: layer.offset);
    } else {
      builder.pushOffset(layer.offset.dx, layer.offset.dy);
    }
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addClipRect(ui.SceneBuilder builder, ClipRectLayer layer) {
    final clip = layer.clipRect;
    if (clip == null) {
      _rejection = 'ClipRectLayer without clip';
      return;
    }
    builder.pushClipRect(clip, clipBehavior: layer.clipBehavior);
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addClipRRect(ui.SceneBuilder builder, ClipRRectLayer layer) {
    final clip = layer.clipRRect;
    if (clip == null) {
      _rejection = 'ClipRRectLayer without clip';
      return;
    }
    builder.pushClipRRect(clip, clipBehavior: layer.clipBehavior);
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addClipRSuperellipse(ui.SceneBuilder builder, ClipRSuperellipseLayer layer) {
    final clip = layer.clipRSuperellipse;
    if (clip == null) {
      _rejection = 'ClipRSuperellipseLayer without clip';
      return;
    }
    builder.pushClipRSuperellipse(clip, clipBehavior: layer.clipBehavior);
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addClipPath(ui.SceneBuilder builder, ClipPathLayer layer) {
    final clip = layer.clipPath;
    if (clip == null) {
      _rejection = 'ClipPathLayer without clip';
      return;
    }
    builder.pushClipPath(clip, clipBehavior: layer.clipBehavior);
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addColorFilter(ui.SceneBuilder builder, ColorFilterLayer layer) {
    final filter = layer.colorFilter;
    if (filter == null) {
      _rejection = 'ColorFilterLayer without filter';
      return;
    }
    builder.pushColorFilter(filter);
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addImageFilter(ui.SceneBuilder builder, ImageFilterLayer layer) {
    final filter = layer.imageFilter;
    if (filter == null) {
      _rejection = 'ImageFilterLayer without filter';
      return;
    }
    builder.pushImageFilter(filter, offset: layer.offset);
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addShaderMask(ui.SceneBuilder builder, ShaderMaskLayer layer) {
    final shader = layer.shader;
    final maskRect = layer.maskRect;
    final blendMode = layer.blendMode;
    if (shader == null || maskRect == null || blendMode == null) {
      _rejection = 'incomplete ShaderMaskLayer';
      return;
    }
    builder.pushShaderMask(shader, maskRect, blendMode);
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addBackdropFilter(ui.SceneBuilder builder, BackdropFilterLayer layer) {
    final filter = layer.filter;
    if (filter == null) {
      _rejection = 'BackdropFilterLayer without filter';
      return;
    }
    final key = layer.backdropKey;
    final backdropId = key == null ? null : _backdropIds.putIfAbsent(key, () => _backdropIds.length + 1);
    builder.pushBackdropFilter(filter, blendMode: layer.blendMode, backdropId: backdropId);
    _addChildren(builder, layer);
    builder.pop();
  }

  void _addLeader(ui.SceneBuilder builder, LeaderLayer layer) {
    final offset = layer.offset;
    if (offset == Offset.zero) return _addChildren(builder, layer);
    builder.pushTransform(Matrix4.translationValues(offset.dx, offset.dy, 0).storage);
    _addChildren(builder, layer);
    builder.pop();
  }

  /// Mirrors [FollowerLayer.addToScene]: hidden while unlinked unless [FollowerLayer.showWhenUnlinked]; otherwise the
  /// transform the last frame composed ([FollowerLayer.applyTransform] uses it for hit testing too).
  void _addFollower(ui.SceneBuilder builder, FollowerLayer layer) {
    final isHidden = layer.link.leader == null && !(layer.showWhenUnlinked ?? false);
    if (isHidden) return;
    final firstChild = layer.firstChild;
    if (firstChild == null) return;
    final transform = Matrix4.identity();
    layer.applyTransform(firstChild, transform);
    builder.pushTransform(transform.storage);
    _addChildren(builder, layer);
    builder.pop();
  }
}
