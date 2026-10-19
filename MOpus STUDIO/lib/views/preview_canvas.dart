// =============================================================================
// MOpus Studio - lib/views/preview_canvas.dart
// -----------------------------------------------------------------------------
// The video preview stage (Module 1).
//
//   * Virtual design space: 1920 x 1080, origin at the canvas center, +Y down.
//     Layer Position/Scale/Rotation live in this space; the widget letterboxes
//     it into whatever space the parent provides (mobile-safe).
//   * Jet Black stage (#050505 page / pure black stage) with Electric Orange
//     (#FF6B00) bounding boxes, selection handles and the rotation gizmo.
//   * Placeholder renderers per layer type so the module is fully usable
//     before the GPU/FFmpeg pipeline lands in a later module.
//   * Gestures: tap to select, drag to move, pinch to scale, twist to rotate.
//     Edits flow through TimelineController (auto-keying included).
// =============================================================================

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controllers/timeline_controller.dart';
import '../models/layer_model.dart';
import '../theme/mopus_theme.dart';

/// Preview widget. Rebuilds on every controller notification.
class PreviewCanvas extends StatefulWidget {
  const PreviewCanvas({super.key, required this.controller});

  final TimelineController controller;

  @override
  State<PreviewCanvas> createState() => _PreviewCanvasState();
}

class _PreviewCanvasState extends State<PreviewCanvas> {
  static const double _designWidth = 1920.0;
  static const double _designHeight = 1080.0;
  static const double _stagePadding = 12.0;

  // Snapshot of the last laid-out frame, consumed by the gesture callbacks.
  Size _stageSize = Size.zero;
  List<_ResolvedVisual> _visuals = const <_ResolvedVisual>[];

  _TransformSession? _session;

  TimelineController get _controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final stage = _fitStage(constraints.biggest);
            final fit = stage.width <= 0 ? 0.0 : stage.width / _designWidth;
            final playhead = _controller.playhead;

            final visuals = <_ResolvedVisual>[];
            for (final layer in _controller.layers) {
              if (!layer.isVisible || !layer.type.isVisual) continue;
              if (!layer.containsTime(playhead)) continue;
              visuals.add(_resolve(layer, playhead));
            }

            _stageSize = stage;
            _visuals = visuals;

            final gizmo = _selectedGizmo(visuals, playhead);

            return Container(
              color: MopusColors.jetBlack,
              padding: const EdgeInsets.all(_stagePadding),
              child: Center(
                child: SizedBox(
                  width: stage.width,
                  height: stage.height,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _handleTapUp,
                    onScaleStart: _handleScaleStart,
                    onScaleUpdate: _handleScaleUpdate,
                    onScaleEnd: (_) => _session = null,
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xFF000000),
                            border: Border.fromBorderSide(
                                BorderSide(color: MopusColors.hairline)),
                          ),
                        ),
                        RepaintBoundary(
                          child: CustomPaint(
                            painter: _StagePainter(items: visuals, fit: fit),
                          ),
                        ),
                        RepaintBoundary(
                          child: CustomPaint(
                            painter: _GizmoPainter(
                              entry: gizmo,
                              stageSize: stage,
                              fit: fit,
                            ),
                          ),
                        ),
                        _buildHud(playhead),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Resolution helpers
  // ---------------------------------------------------------------------------

  _ResolvedVisual _resolve(Layer layer, double playhead) => _ResolvedVisual(
        layer: layer,
        transform: _controller.resolveWorldTransform(layer, atTime: playhead),
        opacity: _controller.resolveOpacity(layer, atTime: playhead),
        baseSize: _baseSizeFor(layer.type),
      );

  /// The layer shown with a gizmo: any selected visual layer, or a selected
  /// Null Object (invisible helper, but must remain grabbable for rigging).
  _ResolvedVisual? _selectedGizmo(List<_ResolvedVisual> visuals, double playhead) {
    final selected = _controller.selectedLayer;
    if (selected == null || !selected.isVisible || selected.isLocked) return null;
    if (!selected.type.isVisual && selected.type != LayerType.nullObject) {
      return null;
    }
    for (final visual in visuals) {
      if (visual.layer.id == selected.id) return visual;
    }
    if (selected.type == LayerType.nullObject) return _resolve(selected, playhead);
    return null;
  }

  Size _baseSizeFor(LayerType type) => switch (type) {
        LayerType.video => const Size(1280, 720),
        LayerType.audio => const Size(0, 0),
        LayerType.text => const Size(800, 240),
        LayerType.shape => const Size(640, 480),
        LayerType.nullObject => const Size(240, 240),
        LayerType.adjustmentLayer => const Size(_designWidth, _designHeight),
      };

  Size _fitStage(Size available) {
    final maxWidth = available.width.isFinite
        ? math.max(available.width - _stagePadding * 2, 0.0)
        : 320.0;
    final maxHeight = available.height.isFinite
        ? math.max(available.height - _stagePadding * 2, 0.0)
        : 180.0;
    if (maxWidth <= 0 || maxHeight <= 0) return Size.zero;

    var width = maxWidth;
    var height = width * _designHeight / _designWidth;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * _designWidth / _designHeight;
    }
    return Size(width, height);
  }

  Offset _layerCenter(_ResolvedVisual visual, Size stage, double fit) => Offset(
        stage.width / 2 + visual.transform.position.x * fit,
        stage.height / 2 + visual.transform.position.y * fit,
      );

  /// Inverse-maps a stage point into the layer's local design space and tests
  /// the base rectangle. Returns the top-most hit (visuals are bottom -> top).
  _ResolvedVisual? _hitTest(Offset stagePoint) {
    final stage = _stageSize;
    if (stage.width <= 0) return null;
    final fit = stage.width / _designWidth;
    for (var i = _visuals.length - 1; i >= 0; i--) {
      final visual = _visuals[i];
      final transform = visual.transform;
      final center = _layerCenter(visual, stage, fit);
      final delta = stagePoint - center;

      final radians = -transform.rotation.radians;
      final cos = math.cos(radians);
      final sin = math.sin(radians);
      final localX = delta.dx * cos - delta.dy * sin;
      final localY = delta.dx * sin + delta.dy * cos;

      final scaleX = (transform.scale.x.abs() < 1e-4 ? 1e-4 : transform.scale.x) * fit;
      final scaleY = (transform.scale.y.abs() < 1e-4 ? 1e-4 : transform.scale.y) * fit;

      if ((localX / scaleX).abs() <= visual.baseSize.width / 2 &&
          (localY / scaleY).abs() <= visual.baseSize.height / 2) {
        return visual;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Gestures
  // ---------------------------------------------------------------------------

  void _handleTapUp(TapUpDetails details) {
    final hit = _hitTest(details.localPosition);
    _controller.selectLayer(hit?.layer.id);
  }

  void _handleScaleStart(ScaleStartDetails details) {
    final hit = _hitTest(details.localFocalPoint);
    if (hit == null || hit.layer.isLocked) {
      _session = null;
      return;
    }
    _controller.selectLayer(hit.layer.id);

    final parent = _controller.layerById(hit.layer.parentId);
    _session = _TransformSession(
      layerId: hit.layer.id,
      start: _controller.resolveLocalTransform(hit.layer),
      startFocal: details.focalPoint,
      parentWorld: parent == null
          ? LayerTransform.identity
          : _controller.resolveWorldTransform(parent),
    );
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final session = _session;
    if (session == null) return;

    final layer = _controller.layerById(session.layerId);
    if (layer == null || layer.isLocked) {
      _session = null;
      return;
    }

    final stage = _stageSize;
    final fit = stage.width <= 0 ? 0.0 : stage.width / _designWidth;
    if (fit <= 0) return;

    // Screen delta -> design-space delta -> parent-local delta.
    final delta = (details.focalPoint - session.startFocal) / fit;
    final radians = -session.parentWorld.rotation.radians;
    final cos = math.cos(radians);
    final sin = math.sin(radians);
    final rotatedX = delta.dx * cos - delta.dy * sin;
    final rotatedY = delta.dx * sin + delta.dy * cos;
    final parentScaleX =
        session.parentWorld.scale.x.abs() < 1e-4 ? 1.0 : session.parentWorld.scale.x;
    final parentScaleY =
        session.parentWorld.scale.y.abs() < 1e-4 ? 1.0 : session.parentWorld.scale.y;

    final factor = details.scale.clamp(0.02, 50.0);
    final rotationDegrees =
        session.start.rotation.degrees + details.rotation * 180.0 / math.pi;

    _controller.updateLayerTransform(
      session.layerId,
      LayerTransform(
        position: Position(
          x: session.start.position.x + rotatedX / parentScaleX,
          y: session.start.position.y + rotatedY / parentScaleY,
        ),
        scale: Scale(
          x: session.start.scale.x * factor,
          y: session.start.scale.y * factor,
        ).clamped(),
        rotation: Rotation(degrees: rotationDegrees),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // HUD
  // ---------------------------------------------------------------------------

  Widget _buildHud(double playhead) {
    final selected = _controller.selectedLayer;
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Stack(
          children: <Widget>[
            const Align(
              alignment: Alignment.topLeft,
              child: _HudChip(
                label: 'PREVIEW',
                accent: true,
              ),
            ),
            Align(
              alignment: Alignment.topRight,
              child: _HudChip(
                label: selected == null ? 'NO SELECTION' : selected.name,
                accent: selected != null,
              ),
            ),
            Align(
              alignment: Alignment.bottomLeft,
              child: _HudChip(
                label:
                    '${_controller.formatTimecode(playhead)}  ·  ${_controller.frameRate}fps',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Gesture session
// -----------------------------------------------------------------------------

class _TransformSession {
  const _TransformSession({
    required this.layerId,
    required this.start,
    required this.startFocal,
    required this.parentWorld,
  });

  final String layerId;
  final LayerTransform start;
  final Offset startFocal;
  final LayerTransform parentWorld;
}

// -----------------------------------------------------------------------------
// Resolved visual (painter-ready snapshot)
// -----------------------------------------------------------------------------

class _ResolvedVisual {
  const _ResolvedVisual({
    required this.layer,
    required this.transform,
    required this.opacity,
    required this.baseSize,
  });

  final Layer layer;
  final LayerTransform transform;
  final double opacity;
  final Size baseSize;
}

// -----------------------------------------------------------------------------
// Stage painter (placeholders per layer type)
// -----------------------------------------------------------------------------

class _StagePainter extends CustomPainter {
  const _StagePainter({required this.items, required this.fit});

  final List<_ResolvedVisual> items;
  final double fit;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || fit <= 0) return;
    canvas.clipRect(Offset.zero & size);

    // Safe-area guide (5% margin, quarter lines) - editor chrome only.
    _paintGuides(canvas, size);

    for (final item in items) {
      final transform = item.transform;
      final center = Offset(
        size.width / 2 + transform.position.x * fit,
        size.height / 2 + transform.position.y * fit,
      );

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(transform.rotation.radians);
      canvas.scale(transform.scale.x * fit, transform.scale.y * fit);

      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: item.baseSize.width,
        height: item.baseSize.height,
      );
      _paintItem(canvas, rect, item);
      canvas.restore();
    }
  }

  void _paintGuides(Canvas canvas, Size size) {
    final margin = Rect.fromLTWH(
      size.width * 0.05,
      size.height * 0.05,
      size.width * 0.9,
      size.height * 0.9,
    );
    final guidePaint = Paint()
      ..color = MopusColors.whiteGhost
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(margin, guidePaint);
    canvas.drawLine(Offset(size.width / 3, 0),
        Offset(size.width / 3, size.height), guidePaint);
    canvas.drawLine(Offset(size.width * 2 / 3, 0),
        Offset(size.width * 2 / 3, size.height), guidePaint);
    canvas.drawLine(Offset(0, size.height / 3),
        Offset(size.width, size.height / 3), guidePaint);
    canvas.drawLine(Offset(0, size.height * 2 / 3),
        Offset(size.width, size.height * 2 / 3), guidePaint);
  }

  void _paintItem(Canvas canvas, Rect rect, _ResolvedVisual item) {
    final alpha = (item.opacity.clamp(0.0, 1.0) * 255).round();
    switch (item.layer.type) {
      case LayerType.video:
        _paintVideo(canvas, rect, item, alpha);
      case LayerType.text:
        _paintText(canvas, rect, item, alpha);
      case LayerType.shape:
        _paintShape(canvas, rect, item, alpha);
      case LayerType.nullObject:
        _paintNullObject(canvas, rect, item, alpha);
      case LayerType.adjustmentLayer:
        _paintAdjustment(canvas, rect, item, alpha);
      case LayerType.audio:
        break; // audio has no visual representation
    }
  }

  void _paintVideo(Canvas canvas, Rect rect, _ResolvedVisual item, int alpha) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));
    final fill = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[Color(0xFF171717), Color(0xFF0B0B0B)],
      ).createShader(rect);
    canvas.drawRRect(rrect, fill);

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFF2A2A2A).withAlpha(alpha);
    canvas.drawRRect(rrect, border);

    // Placeholder play glyph.
    final glyph = Paint()..color = MopusColors.electricOrange.withAlpha(alpha);
    final path = Path()
      ..moveTo(-26, -36)
      ..lineTo(38, 0)
      ..lineTo(-26, 36)
      ..close();
    canvas.drawPath(path, glyph);

    _paintLabel(canvas, item.layer.name, Offset(rect.left + 18, rect.top + 14),
        alpha, 42);
  }

  void _paintText(Canvas canvas, Rect rect, _ResolvedVisual item, int alpha) {
    final painter = TextPainter(
      text: TextSpan(
        text: item.layer.name,
        style: TextStyle(
          color: MopusColors.pureWhite.withAlpha(alpha),
          fontSize: 110,
          fontWeight: FontWeight.w700,
          letterSpacing: -2,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: rect.width);
    painter.paint(
      canvas,
      Offset(rect.center.dx - painter.width / 2,
          rect.center.dy - painter.height / 2),
    );
  }

  void _paintShape(Canvas canvas, Rect rect, _ResolvedVisual item, int alpha) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(24));
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFF141414).withAlpha(alpha));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = MopusColors.electricOrange.withAlpha(alpha),
    );
    _paintLabel(canvas, item.layer.name, Offset(rect.left + 18, rect.top + 14),
        alpha, 40);
  }

  void _paintNullObject(Canvas canvas, Rect rect, _ResolvedVisual item, int alpha) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = MopusColors.pureWhite.withAlpha(math.min(alpha, 90));
    canvas.drawCircle(rect.center, 34, paint);
    _drawDashedLine(canvas, Offset(rect.left, rect.center.dy),
        Offset(rect.right, rect.center.dy), paint, dash: 22, gap: 14);
    _drawDashedLine(canvas, Offset(rect.center.dx, rect.top),
        Offset(rect.center.dx, rect.bottom), paint, dash: 22, gap: 14);
  }

  void _paintAdjustment(Canvas canvas, Rect rect, _ResolvedVisual item, int alpha) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    canvas.drawRRect(
        rrect, Paint()..color = MopusColors.electricOrange.withAlpha(18));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = MopusColors.orangeSoft.withAlpha(math.min(alpha, 120)),
    );
  }

  void _paintLabel(Canvas canvas, String text, Offset offset, int alpha, double size) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: MopusColors.pureWhite.withAlpha(math.min(alpha, 150)),
          fontSize: size,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 900);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _StagePainter oldDelegate) => true;
}

// -----------------------------------------------------------------------------
// Gizmo painter (bounding box, handles, rotation gizmo)
// -----------------------------------------------------------------------------

class _GizmoPainter extends CustomPainter {
  const _GizmoPainter({
    required this.entry,
    required this.stageSize,
    required this.fit,
  });

  final _ResolvedVisual? entry;
  final Size stageSize;
  final double fit;

  @override
  void paint(Canvas canvas, Size size) {
    final item = entry;
    if (item == null || fit <= 0 || size.width <= 0) return;

    final corners = _corners(item);
    if (corners.length != 4) return;

    // Bounding box.
    final box = Path()
      ..moveTo(corners[0].dx, corners[0].dy)
      ..lineTo(corners[1].dx, corners[1].dy)
      ..lineTo(corners[2].dx, corners[2].dy)
      ..lineTo(corners[3].dx, corners[3].dy)
      ..close();
    canvas.drawPath(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = MopusColors.electricOrange,
    );

    // Handles: 4 corners + 4 edge midpoints.
    final topMid = Offset.lerp(corners[0], corners[1], 0.5)!;
    final rightMid = Offset.lerp(corners[1], corners[2], 0.5)!;
    final bottomMid = Offset.lerp(corners[2], corners[3], 0.5)!;
    final leftMid = Offset.lerp(corners[3], corners[0], 0.5)!;
    final handles = <Offset>[
      corners[0],
      topMid,
      corners[1],
      rightMid,
      corners[2],
      bottomMid,
      corners[3],
      leftMid,
    ];

    final handleFill = Paint()..color = MopusColors.pureWhite;
    final handleBorder = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = MopusColors.electricOrange;
    for (final handle in handles) {
      final rect = Rect.fromCenter(
          center: handle, width: MopusMetrics.handleSize, height: MopusMetrics.handleSize);
      canvas.drawRect(rect, handleFill);
      canvas.drawRect(rect.deflate(0.7), handleBorder);
    }

    // Rotation gizmo: connector + knob above the top edge.
    final center = _center(item);
    final up = topMid - center;
    final length = up.distance < 1e-3 ? 1.0 : up.distance;
    final direction = up / length;
    final rotationHandle = topMid + direction * 26;

    canvas.drawLine(
      topMid,
      rotationHandle,
      Paint()
        ..strokeWidth = 1.4
        ..color = MopusColors.electricOrange,
    );
    canvas.drawCircle(
        rotationHandle, 6, Paint()..color = MopusColors.pureWhite);
    canvas.drawCircle(
      rotationHandle,
      6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = MopusColors.electricOrange,
    );

    _paintNamePill(canvas, item.layer.name, corners[0]);
  }

  Offset _center(_ResolvedVisual item) => Offset(
        stageSize.width / 2 + item.transform.position.x * fit,
        stageSize.height / 2 + item.transform.position.y * fit,
      );

  List<Offset> _corners(_ResolvedVisual item) {
    final transform = item.transform;
    final center = _center(item);
    final halfWidth = item.baseSize.width * transform.scale.x * fit / 2;
    final halfHeight = item.baseSize.height * transform.scale.y * fit / 2;
    final radians = transform.rotation.radians;
    final cos = math.cos(radians);
    final sin = math.sin(radians);

    Offset corner(double dx, double dy) => Offset(
          center.dx + dx * halfWidth * cos - dy * halfHeight * sin,
          center.dy + dx * halfWidth * sin + dy * halfHeight * cos,
        );

    return <Offset>[
      corner(-1, -1),
      corner(1, -1),
      corner(1, 1),
      corner(-1, 1),
    ];
  }

  void _paintNamePill(Canvas canvas, String name, Offset anchor) {
    final painter = TextPainter(
      text: TextSpan(
        text: name,
        style: const TextStyle(
          color: MopusColors.pureWhite,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 180);

    final padding = const EdgeInsets.symmetric(horizontal: 7, vertical: 3);
    final origin = Offset(anchor.dx, anchor.dy - painter.height - 24);
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        origin.dx,
        origin.dy,
        painter.width + padding.horizontal,
        painter.height + padding.vertical,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(rrect, Paint()..color = MopusColors.surfaceActive);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = MopusColors.orangeSoft,
    );
    painter.paint(
        canvas, Offset(origin.dx + padding.left, origin.dy + padding.top));
  }

  @override
  bool shouldRepaint(covariant _GizmoPainter oldDelegate) => true;
}

// -----------------------------------------------------------------------------
// HUD chip
// -----------------------------------------------------------------------------

class _HudChip extends StatelessWidget {
  const _HudChip({required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: MopusColors.surfaceElevated,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: accent ? MopusColors.orangeSoft : MopusColors.hairline,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (accent)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 6),
              decoration: const BoxDecoration(
                color: MopusColors.electricOrange,
                shape: BoxShape.circle,
              ),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              label,
              style: MopusText.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Painting helpers
// -----------------------------------------------------------------------------

void _drawDashedLine(
  Canvas canvas,
  Offset from,
  Offset to,
  Paint paint, {
  double dash = 8,
  double gap = 6,
}) {
  final total = (to - from).distance;
  if (total <= 0 || dash <= 0) return;
  final direction = (to - from) / total;
  var travelled = 0.0;
  while (travelled < total) {
    final end = math.min(travelled + dash, total);
    canvas.drawLine(from + direction * travelled, from + direction * end, paint);
    travelled = end + gap;
  }
}
