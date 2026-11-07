import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../internal/coryn_runtime.dart';

/// Captures its subtree for Coryn session replay. Wrap the whole app: `runApp(CorynRoot(child: MyApp()))`.
///
/// Only content inside `CorynRoot` is recorded; the rest of the screen is black in captures. Dialogs and routes of a
/// `MaterialApp` inside it are included. On platforms without the native SDK it only adds a repaint boundary.
class CorynRoot extends SingleChildRenderObjectWidget {
  const CorynRoot({super.key, required Widget super.child});

  @override
  RenderCorynRoot createRenderObject(BuildContext context) {
    CorynRuntime.instance.ensureAttached();
    return RenderCorynRoot(flutterView: View.of(context));
  }

  @override
  void updateRenderObject(BuildContext context, RenderCorynRoot renderObject) {
    renderObject.flutterView = View.of(context);
  }
}

/// Render object of [CorynRoot]: a repaint boundary whose layer the capture rebuilds.
class RenderCorynRoot extends RenderProxyBox {
  // ignore: prefer_initializing_formals
  RenderCorynRoot({required ui.FlutterView flutterView}) : _flutterView = flutterView;

  ui.FlutterView get flutterView => _flutterView;
  ui.FlutterView _flutterView;
  set flutterView(ui.FlutterView value) {
    if (identical(_flutterView, value)) return;
    _flutterView = value;
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;

  /// The layer of the last composited frame, or `null` before the first paint.
  OffsetLayer? get captureLayer => layer as OffsetLayer?;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    CorynRuntime.instance.capture.attachRoot(this);
  }

  @override
  void detach() {
    CorynRuntime.instance.capture.detachRoot(this);
    super.detach();
  }
}
