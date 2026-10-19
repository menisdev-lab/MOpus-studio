// =============================================================================
// MOpus Studio - lib/controllers/animation_controller_extension.dart
// -----------------------------------------------------------------------------
// AnimationPlaybackController (Module 2): the real-time playback extension of
// TimelineController.
//
// It *is* a TimelineController (so every Module 1 view keeps working) and adds:
//   * vsync-driven playback ticking (Ticker) with speed, loop and completion
//     callback - each tick moves the playhead and refreshes the frame cache;
//   * a per-frame transform cache: every layer gets ONE reused [Matrix4]
//     composed with TransformMatrixEngine (Null Object parenting included),
//     plus its resolved local/world transform, opacity, adjustment aggregate
//     and motion-blur plan;
//   * keyframe evaluation through AnimationInterpolator (Module 2) instead of
//     the value-level evaluator, including custom cubic-Bezier easings;
//   * adjustment-layer aggregation from AdjustmentResolver, exposed per layer
//     as effective opacity + effects.
//
// Design notes
//   * Inheritance (not composition) is deliberate: Module 1 widgets already
//     accept a TimelineController, and playback state belongs to the same
//     notifyListeners() cycle the UI listens to already.
//   * The frame cache is keyed by layer id and self-healing: buffers are
//     allocated once per layer and rewritten in place, so a playing frame
//     allocates nothing but one small layer list.
//   * [refresh] is public: call it after bulk edits while paused to keep the
//     cache warm for painters.
// =============================================================================

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show Matrix4;

import '../engine/animation_interpolator.dart';
import '../engine/motion_blur_processor.dart';
import '../engine/transform_matrix_engine.dart';
import '../models/keyframe_model.dart';
import '../models/layer_model.dart';
import 'timeline_controller.dart';

// -----------------------------------------------------------------------------
// Per-layer frame state
// -----------------------------------------------------------------------------

/// Per-layer, per-frame resolved animation data.
///
/// One instance exists per layer for the lifetime of the controller and all
/// buffers are reused every frame. Treat the matrices as read-only: they are
/// overwritten by the next [AnimationPlaybackController.refresh].
class LayerFrameState {
  LayerFrameState(this.layerId);

  final String layerId;

  /// Local matrix: keyframe-resolved transform, before parenting.
  final Matrix4 localMatrix = Matrix4.identity();

  /// World matrix: parent chain applied. Authoritative for painters.
  final Matrix4 worldMatrix = Matrix4.identity();

  /// Value-level world transform (Module 1 semantics) for hit-testing.
  LayerTransform worldTransform = LayerTransform.identity;

  /// Keyframe-resolved local transform (source of the matrices above).
  LayerTransform localTransform = LayerTransform.identity;

  /// Raw layer opacity (0..1).
  double opacity = 1.0;

  /// Opacity after adjustment layers: `opacity * effects.opacityMultiplier`.
  double effectiveOpacity = 1.0;

  /// Adjustment aggregate inherited from adjustment layers above this layer.
  final AdjustmentAggregate effects = AdjustmentAggregate();

  /// True when the layer is visible and its clip covers the current time.
  bool active = false;

  /// Motion blur estimator (smoothed velocity) + its pre-allocated plan.
  final MotionVelocityEstimator velocity = MotionVelocityEstimator();
  final MotionBlurPlan motionBlur = MotionBlurPlan();

  /// Frame revision this state was computed for (controller-internal).
  int revision = -1;

  @override
  String toString() => 'LayerFrameState($layerId, rev $revision, '
      '${active ? 'active' : 'inactive'}, '
      'opacity ${effectiveOpacity.toStringAsFixed(2)})';
}

// -----------------------------------------------------------------------------
// Playback controller
// -----------------------------------------------------------------------------

/// TimelineController + real-time playback + per-frame transform cache.
class AnimationPlaybackController extends TimelineController {
  AnimationPlaybackController({
    super.frameRate = 30,
    TickerProvider? vsync,
    TransformMatrixEngine matrixEngine = const TransformMatrixEngine(),
    MotionBlurProcessor motionBlur = const MotionBlurProcessor(),
    AdjustmentResolver? adjustments,
  })  : _matrixEngine = matrixEngine,
        _motionBlur = motionBlur,
        _adjustments = adjustments ?? AdjustmentResolver() {
    _ticker = vsync?.createTicker(_onTick);
    addListener(_onTimelineChanged);
  }

  /// Guard against a background hitch (GC pause, app switch) producing a huge
  /// playhead jump that would smear one giant motion-blur step.
  static const double _maxFrameStep = 0.1; // seconds

  /// Matches [TimelineController.resolveWorldTransform]'s cycle guard.
  static const int _maxParentDepth = 64;

  final TransformMatrixEngine _matrixEngine;
  final MotionBlurProcessor _motionBlur;
  final AdjustmentResolver _adjustments;
  final Map<String, LayerFrameState> _frameStates =
      <String, LayerFrameState>{};

  Ticker? _ticker;
  Duration? _lastTickElapsed;
  int _frameRevision = 0;
  double _lastRefreshTime = 0.0;
  bool _suppressListenerRefresh = false;
  double _playbackSpeed = 1.0;
  bool _loop = false;

  /// Invoked when playback reaches the end of the project (loop disabled).
  void Function()? onCompleted;

  // -- configuration ----------------------------------------------------------

  TransformMatrixEngine get matrixEngine => _matrixEngine;

  MotionBlurProcessor get motionBlurProcessor => _motionBlur;

  AdjustmentResolver get adjustments => _adjustments;

  /// 1.0 = real time. Clamped to `[0.05, 8.0]`.
  double get playbackSpeed => _playbackSpeed;

  set playbackSpeed(double value) {
    _playbackSpeed = value.clamp(0.05, 8.0).toDouble();
  }

  bool get loop => _loop;

  set loop(bool value) => _loop = value;

  /// 0..1 progress through the project (0 when the project is empty).
  double get playbackProgress {
    final duration = projectDuration;
    if (duration <= 0.0) return 0.0;
    return (playhead / duration).clamp(0.0, 1.0).toDouble();
  }

  // -- playback ---------------------------------------------------------------

  bool get isPlaying => _ticker?.isActive ?? false;

  /// True when a vsync was supplied (playback possible).
  bool get canPlay => _ticker != null;

  /// Attaches a real-time ticker when the controller was built without one.
  /// Ignored when a ticker already exists.
  void attachVsync(TickerProvider vsync) {
    if (_ticker != null) return;
    _ticker = vsync.createTicker(_onTick);
  }

  /// Starts playback. Returns false when nothing can play (no vsync attached,
  /// already playing, or empty project).
  bool play({bool fromStart = false}) {
    final ticker = _ticker;
    if (ticker == null || ticker.isActive) return false;
    if (isEmpty || projectDuration <= 0.0) return false;
    if (fromStart || playhead >= projectDuration) seek(0.0);
    _lastTickElapsed = null;
    ticker.start();
    return true;
  }

  void pause() {
    final ticker = _ticker;
    if (ticker == null || !ticker.isActive) return;
    ticker.stop();
    _lastTickElapsed = null;
  }

  /// Returns true when playback started, false when it stopped.
  bool togglePlayback() {
    if (isPlaying) {
      pause();
      return false;
    }
    return play();
  }

  /// Stops playback and rewinds to the project start.
  void stop() {
    pause();
    seek(0.0);
  }

  void _onTick(Duration elapsed) {
    final previous = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    if (previous == null) return; // first tick only establishes the baseline

    var dt = (elapsed - previous).inMicroseconds * 1e-6 * _playbackSpeed;
    if (dt <= 0.0) return;
    if (dt > _maxFrameStep) dt = _maxFrameStep;

    final duration = projectDuration;
    var next = playhead + dt;

    if (next >= duration) {
      if (_loop && duration > 0.0) {
        next = next % duration;
      } else {
        _runSuppressingListener(() {
          seek(duration);
          refresh();
        });
        pause();
        onCompleted?.call();
        return;
      }
    }

    _runSuppressingListener(() {
      seek(next);
      refresh();
    });
  }

  /// Runs [action] while ignoring the notification it produces, so the tick
  /// path refreshes the frame cache exactly once per frame.
  void _runSuppressingListener(void Function() action) {
    _suppressListenerRefresh = true;
    try {
      action();
    } finally {
      _suppressListenerRefresh = false;
    }
  }

  void _onTimelineChanged() {
    if (_suppressListenerRefresh) return;
    refresh();
  }

  // -- frame cache ------------------------------------------------------------

  /// Recomputes the per-frame animation cache for every layer.
  ///
  /// Runs automatically on every playback tick and on any controller
  /// notification; call it manually after mutating state while paused to make
  /// painters see fresh matrices immediately.
  void refresh() {
    final now = playhead;
    final delta = now - _lastRefreshTime;
    _lastRefreshTime = now;
    _frameRevision++;

    // A frame is "continuous" only when time advanced smoothly since the last
    // refresh. Seeks, loops and edits reset the velocity estimators instead of
    // smearing stale motion across a jump.
    final continuous = delta > 0.0 && delta <= _maxFrameStep;
    final dt = continuous ? delta : 0.0;

    final layers = this.layers; // the only per-frame list allocation
    final count = layers.length;

    // Pass 1: register the adjustment layers that are active on this frame.
    _adjustments.beginFrame();
    for (var i = 0; i < count; i++) {
      final layer = layers[i];
      if (layer.type != LayerType.adjustmentLayer) continue;
      if (!layer.isVisible || !layer.containsTime(now)) continue;
      _adjustments.register(layerId: layer.id, stackIndex: i);
    }

    // Pass 2: resolve local values, matrices (parenting included) and effects.
    for (var i = 0; i < count; i++) {
      final layer = layers[i];
      final state = _stateFor(layer.id);
      _resolveMatrices(layer, state, now, 0);

      state.worldTransform = resolveWorldTransform(layer, atTime: now);
      state.opacity = resolveOpacity(layer, atTime: now);
      state.effects.copyFrom(_adjustments.aggregateFor(i));
      state.effectiveOpacity =
          (state.opacity * state.effects.opacityMultiplier)
              .clamp(0.0, 1.0)
              .toDouble();

      if (continuous && state.active) {
        final worldPosition = state.worldTransform.position;
        final worldScale = state.worldTransform.scale;
        state.velocity.update(
          dt: dt,
          x: worldPosition.x,
          y: worldPosition.y,
          rotationDegrees: state.worldTransform.rotation.degrees,
          scale: (worldScale.x + worldScale.y) * 0.5,
        );
        _motionBlur.process(
          estimator: state.velocity,
          plan: state.motionBlur,
          dt: dt,
        );
      } else {
        state.velocity.reset();
        state.motionBlur.clear();
      }
    }

    // Drop states of deleted layers (no-op on most frames).
    _frameStates.removeWhere((id, state) => state.revision != _frameRevision);
  }

  /// Resolves matrices for [layer] and, recursively, its ancestors. Memoized on
  /// the frame revision, so shared parents are multiplied once per frame and
  /// any layer order in the list resolves correctly. The depth guard stops
  /// corrupted/cyclic parent chains.
  void _resolveMatrices(
    Layer layer,
    LayerFrameState state,
    double time,
    int depth,
  ) {
    if (state.revision == _frameRevision) return;
    state.revision = _frameRevision;

    state.active = layer.isVisible && layer.containsTime(time);
    state.localTransform = resolveLocalTransform(layer, atTime: time);
    _matrixEngine.composeInto(state.localMatrix, state.localTransform);

    final parent = layerById(layer.parentId);
    if (parent == null || depth >= _maxParentDepth) {
      state.worldMatrix.setFrom(state.localMatrix);
      return;
    }

    final parentState = _stateFor(parent.id);
    _resolveMatrices(parent, parentState, time, depth + 1);

    // world = parentWorld * local (children live in parent space).
    state.worldMatrix.setFrom(parentState.worldMatrix);
    state.worldMatrix.multiply(state.localMatrix);
  }

  LayerFrameState _stateFor(String layerId) {
    var state = _frameStates[layerId];
    if (state == null) {
      state = LayerFrameState(layerId);
      _frameStates[layerId] = state;
    }
    return state;
  }

  // -- Module 2 evaluation overrides -------------------------------------------

  /// Keyframe-resolved local transform through [AnimationInterpolator]
  /// (custom cubic-Bezier easings included). Value-equivalent to Module 1's
  /// evaluator, with an early-out for static layers.
  @override
  LayerTransform resolveLocalTransform(Layer layer, {double? atTime}) {
    if (!hasKeyframes(layer.id)) return layer.transform;
    final time = atTime ?? playhead;
    return AnimationInterpolator.transformAt(
      base: layer.transform,
      time: time,
      positionTrack: keyframeTrackRef(layer.id, KeyframeProperty.position),
      scaleTrack: keyframeTrackRef(layer.id, KeyframeProperty.scale),
      rotationTrack: keyframeTrackRef(layer.id, KeyframeProperty.rotation),
    );
  }

  @override
  double resolveOpacity(Layer layer, {double? atTime}) =>
      AnimationInterpolator.opacityAt(
        layer.opacity,
        keyframeTrackRef(layer.id, KeyframeProperty.opacity),
        atTime ?? playhead,
      );

  // -- cached read accessors (for painters) ------------------------------------

  /// Frame-cached world matrix, or a freshly composed one when the cache is
  /// cold. The returned instance is reused by the next frame - read it during
  /// the current paint, never store or mutate it.
  Matrix4 worldMatrixOf(Layer layer) {
    final state = _frameStates[layer.id];
    if (state != null && state.revision == _frameRevision) {
      return state.worldMatrix;
    }
    return _matrixEngine.compose(resolveWorldTransform(layer));
  }

  /// Frame-cached state of [layerId], or null before the first [refresh].
  LayerFrameState? frameStateOf(String layerId) {
    final state = _frameStates[layerId];
    return state != null && state.revision == _frameRevision ? state : null;
  }

  /// Effective opacity after adjustment layers.
  double effectiveOpacityOf(Layer layer) =>
      frameStateOf(layer.id)?.effectiveOpacity ?? resolveOpacity(layer);

  /// Adjustment aggregate inherited by [layer] this frame. On the hot path the
  /// shared state aggregate is returned (treat as read-only); cold callers get
  /// a fresh neutral aggregate they own.
  AdjustmentAggregate effectsOf(Layer layer) =>
      frameStateOf(layer.id)?.effects ?? AdjustmentAggregate();

  /// Motion blur for [layer] on this frame, or null when it is not smearing.
  MotionBlurPlan? motionBlurOf(Layer layer) {
    final state = frameStateOf(layer.id);
    if (state == null || !state.motionBlur.isActive) return null;
    return state.motionBlur;
  }

  /// Assigns the effect an adjustment layer passes down to the layers below.
  /// Reset with [AdjustmentEffect.neutral]. Persistence lands with the project
  /// module; the resolver keeps the value in memory for now.
  void setAdjustmentEffect(String layerId, AdjustmentEffect effect) {
    final layer = layerById(layerId);
    if (layer == null || layer.type != LayerType.adjustmentLayer) return;
    _adjustments.setEffect(layerId, effect);
    notifyListeners(); // -> _onTimelineChanged -> refresh()
  }

  // -- lifecycle ---------------------------------------------------------------

  @override
  void dispose() {
    removeListener(_onTimelineChanged);
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    _frameStates.clear();
    super.dispose();
  }
}

// -----------------------------------------------------------------------------
// View convenience
// -----------------------------------------------------------------------------

/// Bridge for widgets that hold a plain [TimelineController]: playback-aware
/// views can upgrade transparently and fall back when they cannot.
extension TimelineControllerAnimationAccess on TimelineController {
  /// This controller seen as a playback controller, or null when it is not one.
  AnimationPlaybackController? get playback => this is AnimationPlaybackController
      ? this as AnimationPlaybackController
      : null;
}
