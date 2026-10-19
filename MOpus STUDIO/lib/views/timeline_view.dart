// =============================================================================
// MOpus Studio - lib/views/timeline_view.dart
// -----------------------------------------------------------------------------
// Multi-track timeline UI (Module 1).
//
//   * Fixed track-header column (icons per layer type, visibility + lock).
//   * Zoomable, horizontally scrollable ruler + lane area (pinch on the ruler,
//     +/- buttons in the toolbar).
//   * Playhead scrubber across every track with frame-accurate seek.
//   * Snap-to-grid: layer edges are magnetic while scrubbing or dragging clips;
//     a dashed Electric Orange guide marks an active snap.
//   * Clip drag = shift layer timing (respects Layer.isLocked).
//
// Layout / scroll-sync map
//   _lanesHScroll   (master, lanes)   -> _rulerHScroll  (slave, ruler)
//   _lanesVScroll   (master, lanes)   -> _headersVScroll (slave, headers)
// =============================================================================

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controllers/timeline_controller.dart';
import '../models/layer_model.dart';
import '../theme/mopus_theme.dart';

/// The timeline. Put it under an [Expanded] / [Flexible]: it fills its box.
class TimelineView extends StatefulWidget {
  const TimelineView({super.key, required this.controller});

  final TimelineController controller;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  static const double _minPps = 12.0;
  static const double _maxPps = 600.0;
  static const double _zoomStep = 1.5;
  static const double _snapTolerancePx = 8.0;

  final ScrollController _lanesHScroll = ScrollController();
  final ScrollController _rulerHScroll = ScrollController();
  final ScrollController _lanesVScroll = ScrollController();
  final ScrollController _headersVScroll = ScrollController();

  double _pps = 80.0; // pixels per second
  bool _snapEnabled = true;
  double? _snapIndicator;
  double _viewportWidth = 0.0;

  // Playhead drag session.
  bool _scrubbing = false;
  double _playheadDragStartTime = 0.0;
  double _playheadDragDx = 0.0;

  // Ruler pinch-zoom session.
  double _zoomStartPps = 80.0;
  double _zoomAnchorTime = 0.0;
  double _zoomAnchorViewportX = 0.0;

  // Clip drag session.
  double _clipDragStartTime = 0.0;
  double _clipDragDx = 0.0;

  TimelineController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _lanesHScroll.addListener(_syncRuler);
    _lanesVScroll.addListener(_syncHeaders);
  }

  @override
  void dispose() {
    _lanesHScroll.removeListener(_syncRuler);
    _lanesVScroll.removeListener(_syncHeaders);
    _lanesHScroll.dispose();
    _rulerHScroll.dispose();
    _lanesVScroll.dispose();
    _headersVScroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Scroll synchronization
  // ---------------------------------------------------------------------------

  void _syncRuler() {
    if (!_rulerHScroll.hasClients) return;
    _rulerHScroll.jumpTo(_lanesHScroll.offset);
  }

  void _syncHeaders() {
    if (!_headersVScroll.hasClients || !_lanesVScroll.hasClients) return;
    final maxOffset = _headersVScroll.position.maxScrollExtent;
    _headersVScroll.jumpTo(_lanesVScroll.offset.clamp(0.0, maxOffset).toDouble());
  }

  // ---------------------------------------------------------------------------
  // Zoom
  // ---------------------------------------------------------------------------

  double get _contentWidth => math.max(
        _viewportWidth,
        _controller.projectDuration * _pps + 240.0,
      );

  void _zoomBy(double factor) {
    final anchorTime = _controller.playhead;
    final offset = _lanesHScroll.hasClients ? _lanesHScroll.offset : 0.0;
    final anchorViewportX = anchorTime * _pps - offset;
    final newPps = (_pps * factor).clamp(_minPps, _maxPps).toDouble();
    if ((newPps - _pps).abs() < 0.01) return;

    setState(() => _pps = newPps);
    _applyScrollOffset(anchorTime * newPps - anchorViewportX);
  }

  /// Post-frame jump so it runs after the new content width is laid out.
  void _applyScrollOffset(double desiredOffset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_lanesHScroll.hasClients) return;
      final maxOffset = _lanesHScroll.position.maxScrollExtent;
      _lanesHScroll.jumpTo(desiredOffset.clamp(0.0, maxOffset).toDouble());
    });
  }

  // ---------------------------------------------------------------------------
  // Scrubbing / snapping
  // ---------------------------------------------------------------------------

  void _scrubTo(double rawTime) {
    var time = rawTime < 0 ? 0.0 : rawTime;
    double? indicator;
    if (_snapEnabled) {
      final snapped =
          _controller.nearestSnapPoint(time, _snapTolerancePx / _pps);
      if (snapped != null) {
        time = snapped;
        indicator = snapped;
      }
    }
    if (indicator != _snapIndicator) {
      setState(() => _snapIndicator = indicator);
    }
    _controller.seek(time);
  }

  void _handleRulerScaleStart(ScaleStartDetails details) {
    final offset = _lanesHScroll.hasClients ? _lanesHScroll.offset : 0.0;
    _zoomStartPps = _pps;
    _zoomAnchorTime = details.localFocalPoint.dx / _pps;
    _zoomAnchorViewportX = details.localFocalPoint.dx - offset;
  }

  void _handleRulerScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2) {
      final newPps = (_zoomStartPps * details.scale).clamp(_minPps, _maxPps).toDouble();
      if ((newPps - _pps).abs() < 0.01) return;
      setState(() => _pps = newPps);
      _applyScrollOffset(_zoomAnchorTime * newPps - _zoomAnchorViewportX);
    } else {
      _scrubTo(details.localFocalPoint.dx / _pps);
    }
  }

  void _handleRulerScaleEnd(ScaleEndDetails details) {
    if (_snapIndicator != null) {
      setState(() => _snapIndicator = null);
    }
  }

  // ---------------------------------------------------------------------------
  // Playhead handle
  // ---------------------------------------------------------------------------

  void _handlePlayheadDragStart(DragStartDetails details) {
    _playheadDragStartTime = _controller.playhead;
    _playheadDragDx = 0.0;
    setState(() => _scrubbing = true);
  }

  void _handlePlayheadDragUpdate(DragUpdateDetails details) {
    _playheadDragDx += details.delta.dx;
    _scrubTo(_playheadDragStartTime + _playheadDragDx / _pps);
  }

  void _handlePlayheadDragEnd(DragEndDetails details) {
    setState(() {
      _scrubbing = false;
      _snapIndicator = null;
    });
  }

  // ---------------------------------------------------------------------------
  // Clip dragging (shift layer timing)
  // ---------------------------------------------------------------------------

  void _beginClipDrag(Layer layer) {
    if (layer.isLocked) return;
    _controller.selectLayer(layer.id);
    _clipDragStartTime = layer.startTime;
    _clipDragDx = 0.0;
  }

  void _updateClipDrag(String layerId, DragUpdateDetails details) {
    final layer = _controller.layerById(layerId);
    if (layer == null || layer.isLocked) return;

    _clipDragDx += details.delta.dx;
    var proposed = _clipDragStartTime + _clipDragDx / _pps;
    if (proposed < 0) proposed = 0.0;

    var target = proposed;
    double? indicator;
    if (_snapEnabled) {
      final tolerance = _snapTolerancePx / _pps;
      var bestDistance = tolerance;
      for (final point in _controller.snapPoints) {
        // Snap the clip start to a neighbour edge.
        final startDistance = (point - proposed).abs();
        if (startDistance <= bestDistance &&
            (point - _clipDragStartTime).abs() > 1e-6) {
          bestDistance = startDistance;
          target = point;
          indicator = point;
        }
        // Snap the clip end to a neighbour edge.
        final endTarget = point - layer.duration;
        final endDistance = (point - (proposed + layer.duration)).abs();
        if (endDistance <= bestDistance &&
            endTarget >= 0 &&
            (endTarget - _clipDragStartTime).abs() > 1e-6) {
          bestDistance = endDistance;
          target = endTarget;
          indicator = point;
        }
      }
    }

    if (indicator != _snapIndicator) {
      setState(() => _snapIndicator = indicator);
    }
    _controller.shiftLayerTiming(layerId, startTime: target);
  }

  void _endClipDrag() {
    if (_snapIndicator != null) {
      setState(() => _snapIndicator = null);
    }
  }

  // ---------------------------------------------------------------------------
  // Toolbar actions
  // ---------------------------------------------------------------------------

  void _toggleKeyframes() {
    final layer = _controller.selectedLayer;
    if (layer == null || layer.isLocked) return;
    if (_controller.hasKeyframesAtPlayhead(layer.id)) {
      _controller.removeKeyframesAtPlayhead(layer.id);
    } else {
      _controller.addKeyframesAtPlayhead(layer.id);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final totalWidth =
                constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
            _viewportWidth =
                math.max(totalWidth - MopusMetrics.trackHeaderWidth, 80.0);

            return Container(
              color: MopusColors.jetBlack,
              child: Column(
                children: <Widget>[
                  _buildToolbar(),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _buildHeaderColumn(),
                        Expanded(child: _buildScrollableArea(_contentWidth)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildToolbar() {
    final controller = _controller;
    final selected = controller.selectedLayer;
    return Container(
      height: MopusMetrics.toolbarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MopusColors.hairline)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 430;
          return Row(
            children: <Widget>[
              if (wide) ...<Widget>[
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: const BoxDecoration(
                    color: MopusColors.electricOrange,
                    shape: BoxShape.circle,
                  ),
                ),
                const Text('TIMELINE', style: MopusText.sectionTitle),
              ],
              const Spacer(),
              _ToolbarIcon(
                icon: Icons.grid_on,
                tooltip: _snapEnabled ? 'Snap: on' : 'Snap: off',
                active: _snapEnabled,
                onTap: () => setState(() => _snapEnabled = !_snapEnabled),
              ),
              _ToolbarIcon(
                icon: Icons.zoom_out,
                tooltip: 'Zoom out',
                onTap: () => _zoomBy(1 / _zoomStep),
              ),
              SizedBox(
                width: 46,
                child: Text(
                  '${_pps.round()} px/s',
                  textAlign: TextAlign.center,
                  style: MopusText.caption,
                ),
              ),
              _ToolbarIcon(
                icon: Icons.zoom_in,
                tooltip: 'Zoom in',
                onTap: () => _zoomBy(_zoomStep),
              ),
              _ToolbarIcon(
                icon: Icons.diamond_outlined,
                tooltip: 'Keyframes at playhead',
                enabled: selected != null && !selected.isLocked,
                active: selected != null &&
                    controller.hasKeyframesAtPlayhead(selected.id),
                onTap: _toggleKeyframes,
              ),
              PopupMenuButton<LayerType>(
                tooltip: 'Add layer',
                offset: const Offset(0, 32),
                onSelected: (type) => controller.addLayerOfType(type),
                itemBuilder: (context) => <PopupMenuEntry<LayerType>>[
                  for (final type in LayerType.values)
                    PopupMenuItem<LayerType>(
                      value: type,
                      height: 38,
                      child: Row(
                        children: <Widget>[
                          Icon(_iconFor(type),
                              size: 15, color: MopusColors.electricOrange),
                          const SizedBox(width: 10),
                          Text(type.label, style: MopusText.label),
                        ],
                      ),
                    ),
                ],
                child: const _ToolbarIcon(icon: Icons.add, active: true),
              ),
              const SizedBox(width: 6),
              Text(
                controller.formatTimecode(controller.playhead),
                style: MopusText.label,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeaderColumn() {
    final count = _controller.layerCount;
    return SizedBox(
      width: MopusMetrics.trackHeaderWidth,
      child: Column(
        children: <Widget>[
          Container(
            height: MopusMetrics.rulerHeight,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: MopusColors.hairline),
                right: BorderSide(color: MopusColors.hairline),
              ),
            ),
            child: const Text('LAYERS', style: MopusText.caption),
          ),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: MopusColors.hairline)),
              ),
              child: ListView.builder(
                controller: _headersVScroll,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: count,
                itemBuilder: (context, index) => _buildTrackHeader(index),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScrollableArea(double contentWidth) {
    return Stack(
      children: <Widget>[
        Column(
          children: <Widget>[
            // ---- Time ruler ------------------------------------------------
            SizedBox(
              height: MopusMetrics.rulerHeight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                controller: _rulerHScroll,
                physics: const NeverScrollableScrollPhysics(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _handleRulerScaleStart,
                  onScaleUpdate: _handleRulerScaleUpdate,
                  onScaleEnd: _handleRulerScaleEnd,
                  child: CustomPaint(
                    size: Size(contentWidth, MopusMetrics.rulerHeight),
                    painter: _RulerPainter(pps: _pps, controller: _controller),
                  ),
                ),
              ),
            ),
            // ---- Track lanes ------------------------------------------------
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                controller: _lanesHScroll,
                child: SizedBox(
                  width: contentWidth,
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: CustomPaint(painter: _GridPainter(pps: _pps)),
                      ),
                      ListView.builder(
                        controller: _lanesVScroll,
                        padding: EdgeInsets.zero,
                        itemCount: _controller.layerCount,
                        itemBuilder: (context, index) => _buildLane(index),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        // ---- Playhead + snap overlay ----------------------------------------
        AnimatedBuilder(
          animation:
              Listenable.merge(<Listenable>[_lanesHScroll, _controller]),
          builder: (context, _) {
            final offset = _lanesHScroll.hasClients ? _lanesHScroll.offset : 0.0;
            final playheadX = _controller.playhead * _pps - offset;
            final snapTime = _snapIndicator;
            final snapX = snapTime == null ? null : snapTime * _pps - offset;
            final visible = playheadX >= -12 && playheadX <= _viewportWidth + 12;

            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _OverlayPainter(
                        playheadX: playheadX,
                        snapX: snapX,
                        scrubbing: _scrubbing,
                        timeLabel:
                            _controller.formatTimecode(_controller.playhead),
                      ),
                    ),
                  ),
                ),
                if (visible)
                  Positioned(
                    left: playheadX - 12,
                    top: 0,
                    bottom: 0,
                    width: 24,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragStart: _handlePlayheadDragStart,
                      onHorizontalDragUpdate: _handlePlayheadDragUpdate,
                      onHorizontalDragEnd: _handlePlayheadDragEnd,
                      onHorizontalDragCancel: () =>
                          setState(() => _scrubbing = false),
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
            );
          },
        ),
        if (_controller.isEmpty) _buildEmptyState(),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: MopusColors.surface,
              borderRadius: BorderRadius.circular(MopusMetrics.cornerRadius),
              border: Border.all(color: MopusColors.hairline),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.layers_outlined,
                    size: 22, color: MopusColors.textTertiary),
                SizedBox(height: 8),
                Text('No layers yet', style: MopusText.label),
                SizedBox(height: 2),
                Text('Tap  +  to add your first layer',
                    style: MopusText.caption),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Layer _layerAtTrack(int trackIndex) {
    final layers = _controller.layers;
    return layers[layers.length - 1 - trackIndex];
  }

  Widget _buildLane(int trackIndex) {
    final controller = _controller;
    final layer = _layerAtTrack(trackIndex);
    final selected = controller.selectedLayerId == layer.id;
    final keyframeXs = <double>[
      for (final time in controller.keyframeTimes(layer.id))
        (time - layer.startTime) * _pps,
    ];

    return SizedBox(
      height: MopusMetrics.laneHeight,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: trackIndex.isEven
                    ? MopusColors.surface
                    : MopusColors.jetBlack,
                border: const Border(
                  bottom: BorderSide(color: MopusColors.hairline),
                ),
              ),
            ),
          ),
          Positioned(
            left: layer.startTime * _pps,
            top: MopusMetrics.clipInsetY,
            width: math.max(layer.duration * _pps, 34.0),
            height: MopusMetrics.laneHeight - MopusMetrics.clipInsetY * 2,
            child: _buildClip(layer, selected, keyframeXs),
          ),
        ],
      ),
    );
  }

  Widget _buildClip(Layer layer, bool selected, List<double> keyframeXs) {
    final locked = layer.isLocked;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _controller.selectLayer(layer.id),
      onHorizontalDragStart: locked ? null : (_) => _beginClipDrag(layer),
      onHorizontalDragUpdate:
          locked ? null : (details) => _updateClipDrag(layer.id, details),
      onHorizontalDragEnd: locked ? null : (_) => _endClipDrag(),
      onHorizontalDragCancel: locked ? null : _endClipDrag,
      child: Opacity(
        opacity: layer.isVisible ? 1.0 : 0.45,
        child: Container(
          decoration: BoxDecoration(
            color: selected
                ? MopusColors.surfaceActive
                : MopusColors.surfaceHighlight,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color:
                  selected ? MopusColors.electricOrange : MopusColors.hairline,
              width: selected ? 1.5 : 1,
            ),
            boxShadow: selected
                ? const <BoxShadow>[
                    BoxShadow(color: MopusColors.orangeGlow, blurRadius: 10),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(5)),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        _buildClipContent(layer, selected, constraints.maxWidth),
                  ),
                ),
                if (keyframeXs.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 3,
                    height: 8,
                    child: CustomPaint(
                      painter: _KeyframeStripPainter(xs: keyframeXs),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildClipContent(Layer layer, bool selected, double maxWidth) {
    final compact = maxWidth < 64;
    return Row(
      children: <Widget>[
        Container(width: 3, color: MopusColors.electricOrange),
        const SizedBox(width: 7),
        Icon(
          _iconFor(layer.type),
          size: 13,
          color: selected ? MopusColors.electricOrange : MopusColors.textSecondary,
        ),
        if (!compact) ...<Widget>[
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  layer.name,
                  style: MopusText.label.copyWith(fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  '${layer.duration.toStringAsFixed(1)}s',
                  style: MopusText.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (layer.isLocked)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.lock_outline,
                  size: 11, color: MopusColors.textTertiary),
            ),
        ],
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildTrackHeader(int trackIndex) {
    final controller = _controller;
    final layer = _layerAtTrack(trackIndex);
    final selected = controller.selectedLayerId == layer.id;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => controller.selectLayer(layer.id),
      child: Container(
        height: MopusMetrics.laneHeight,
        decoration: BoxDecoration(
          color:
              selected ? MopusColors.surfaceElevated : MopusColors.surface,
          border: const Border(
            bottom: BorderSide(color: MopusColors.hairline),
          ),
        ),
        child: Row(
          children: <Widget>[
            const SizedBox(width: 8),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: selected
                    ? MopusColors.orangeMuted
                    : MopusColors.surfaceHighlight,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color:
                      selected ? MopusColors.orangeSoft : MopusColors.hairline,
                ),
              ),
              child: Icon(
                _iconFor(layer.type),
                size: 14,
                color: selected
                    ? MopusColors.electricOrange
                    : MopusColors.textSecondary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    layer.name,
                    style: MopusText.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    layer.type.label,
                    style: MopusText.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            _HeaderToggle(
              icon: layer.isVisible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              active: layer.isVisible,
              onTap: () => controller.setLayerVisible(layer.id, !layer.isVisible),
            ),
            _HeaderToggle(
              icon: layer.isLocked ? Icons.lock_outline : Icons.lock_open,
              active: layer.isLocked,
              onTap: () => controller.setLayerLocked(layer.id, !layer.isLocked),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Toolbar / header widgets
// -----------------------------------------------------------------------------

class _ToolbarIcon extends StatelessWidget {
  const _ToolbarIcon({
    required this.icon,
    this.tooltip,
    this.active = false,
    this.enabled = true,
    this.onTap,
  });

  final IconData icon;
  final String? tooltip;
  final bool active;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = !enabled
        ? MopusColors.textDisabled
        : active
            ? MopusColors.electricOrange
            : MopusColors.textSecondary;

    final child = Container(
      width: 28,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: active && enabled ? MopusColors.orangeMuted : Colors.transparent,
        border: Border.all(
          color: active && enabled
              ? MopusColors.orangeSoft
              : Colors.transparent,
        ),
      ),
      child: Icon(icon, size: 15, color: color),
    );

    final Widget tappable = onTap == null
        ? child
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? onTap : null,
            child: child,
          );

    if (tooltip == null) return tappable;
    return Tooltip(message: tooltip!, child: tappable);
  }
}

class _HeaderToggle extends StatelessWidget {
  const _HeaderToggle({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 22,
        height: 30,
        child: Icon(
          icon,
          size: 13,
          color: active ? MopusColors.textSecondary : MopusColors.textDisabled,
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Ruler painter
// -----------------------------------------------------------------------------

class _RulerPainter extends CustomPainter {
  const _RulerPainter({required this.pps, required this.controller});

  final double pps;
  final TimelineController controller;

  /// Labeled tick interval, adapted to the zoom level.
  static double labelStep(double pps) {
    const candidates = <double>[
      0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300,
    ];
    for (final candidate in candidates) {
      if (candidate * pps >= 64) return candidate;
    }
    return 600;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = MopusColors.surface);

    final step = labelStep(pps);
    final minor = step / 5;

    final minorPaint = Paint()
      ..color = MopusColors.whiteFaint
      ..strokeWidth = 1;
    final majorPaint = Paint()
      ..color = MopusColors.textTertiary
      ..strokeWidth = 1;
    const labelStyle = TextStyle(
      color: MopusColors.textTertiary,
      fontSize: 9,
      fontWeight: FontWeight.w500,
    );

    if (minor * pps >= 6) {
      for (var t = 0.0; t * pps < size.width; t += minor) {
        final x = t * pps;
        canvas.drawLine(
          Offset(x, size.height - 5),
          Offset(x, size.height),
          minorPaint,
        );
      }
    }

    for (var t = 0.0; t * pps < size.width; t += step) {
      final x = t * pps;
      canvas.drawLine(
        Offset(x, size.height - 10),
        Offset(x, size.height),
        majorPaint,
      );
      final painter = TextPainter(
        text: TextSpan(text: controller.formatRulerLabel(t), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset(x + 4, 4));
    }

    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()
        ..color = MopusColors.hairline
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _RulerPainter oldDelegate) =>
      oldDelegate.pps != pps || oldDelegate.controller != controller;
}

// -----------------------------------------------------------------------------
// Grid painter (lane background)
// -----------------------------------------------------------------------------

class _GridPainter extends CustomPainter {
  const _GridPainter({required this.pps});

  final double pps;

  @override
  void paint(Canvas canvas, Size size) {
    final step = _RulerPainter.labelStep(pps);
    final paint = Paint()
      ..color = MopusColors.whiteGhost
      ..strokeWidth = 1;
    for (var t = step; t * pps < size.width; t += step) {
      final x = t * pps;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.pps != pps;
}

// -----------------------------------------------------------------------------
// Overlay painter (playhead + snap indicator)
// -----------------------------------------------------------------------------

class _OverlayPainter extends CustomPainter {
  const _OverlayPainter({
    required this.playheadX,
    required this.snapX,
    required this.scrubbing,
    required this.timeLabel,
  });

  final double playheadX;
  final double? snapX;
  final bool scrubbing;
  final String timeLabel;

  @override
  void paint(Canvas canvas, Size size) {
    // ---- Snap indicator (dashed orange guide + diamond) -------------------
    final snap = snapX;
    if (snap != null && snap >= -1 && snap <= size.width + 1) {
      final snapPaint = Paint()
        ..color = MopusColors.orangeSoft
        ..strokeWidth = 1;
      _dashLine(
        canvas,
        Offset(snap, 0),
        Offset(snap, size.height),
        snapPaint,
        dash: 6,
        gap: 5,
      );
      final diamond = Path()
        ..moveTo(snap, 3)
        ..lineTo(snap + 4, 8)
        ..lineTo(snap, 13)
        ..lineTo(snap - 4, 8)
        ..close();
      canvas.drawPath(diamond, Paint()..color = MopusColors.electricOrange);
    }

    if (playheadX < -1 || playheadX > size.width + 1) return;

    // ---- Playhead line ----------------------------------------------------
    canvas.drawLine(
      Offset(playheadX, 0),
      Offset(playheadX, size.height),
      Paint()
        ..color = MopusColors.electricOrange
        ..strokeWidth = 2,
    );

    // ---- Top handle -------------------------------------------------------
    final handle = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(playheadX, 8), width: 14, height: 12),
      const Radius.circular(3),
    );
    canvas.drawRRect(handle, Paint()..color = MopusColors.electricOrange);

    // ---- Timecode chip while scrubbing -------------------------------------
    if (!scrubbing) return;
    final textPainter = TextPainter(
      text: TextSpan(
        text: timeLabel,
        style: const TextStyle(
          color: MopusColors.pureWhite,
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final chipWidth = textPainter.width + 14;
    const chipHeight = 16.0;
    final chipLeft =
        math.min(playheadX + 9, math.max(size.width - chipWidth - 4, 4.0));
    final chipRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(chipLeft, 20, chipWidth, chipHeight),
      const Radius.circular(4),
    );
    canvas.drawRRect(chipRect, Paint()..color = MopusColors.surfaceActive);
    canvas.drawRRect(
      chipRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = MopusColors.electricOrange,
    );
    textPainter.paint(
      canvas,
      Offset(chipLeft + 7, 20 + (chipHeight - textPainter.height) / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) =>
      oldDelegate.playheadX != playheadX ||
      oldDelegate.snapX != snapX ||
      oldDelegate.scrubbing != scrubbing ||
      oldDelegate.timeLabel != timeLabel;
}

// -----------------------------------------------------------------------------
// Keyframe diamonds on clips
// -----------------------------------------------------------------------------

class _KeyframeStripPainter extends CustomPainter {
  const _KeyframeStripPainter({required this.xs});

  /// Positions in clip-local pixels (clip start = 0), computed by the view.
  final List<double> xs;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final paint = Paint()..color = MopusColors.electricOrange;
    final centerY = size.height / 2;
    for (final x in xs) {
      if (x < 2 || x > size.width - 2) continue;
      final diamond = Path()
        ..moveTo(x, centerY - 3.5)
        ..lineTo(x + 3.5, centerY)
        ..lineTo(x, centerY + 3.5)
        ..lineTo(x - 3.5, centerY)
        ..close();
      canvas.drawPath(diamond, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _KeyframeStripPainter oldDelegate) => true;
}

// -----------------------------------------------------------------------------
// Painting helper
// -----------------------------------------------------------------------------

void _dashLine(
  Canvas canvas,
  Offset from,
  Offset to,
  Paint paint, {
  double dash = 6,
  double gap = 5,
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

IconData _iconFor(LayerType type) => switch (type) {
      LayerType.video => Icons.videocam_outlined,
      LayerType.audio => Icons.graphic_eq,
      LayerType.text => Icons.text_fields,
      LayerType.shape => Icons.crop_square,
      LayerType.nullObject => Icons.center_focus_weak,
      LayerType.adjustmentLayer => Icons.tune,
    };
