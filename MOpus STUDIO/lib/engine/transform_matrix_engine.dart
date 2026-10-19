// =============================================================================
// MOpus Studio - lib/engine/transform_matrix_engine.dart
// -----------------------------------------------------------------------------
// Transform matrix engine (Module 2).
//
//   * 2D composition: `M = T(position) * R(rotation) * S(scale)` around an
//     optional anchor/pivot, mirroring Module 1 conventions (canvas-center
//     origin, +Y down, clockwise degrees).
//   * 3D composition: optional Z offset, X/Y rotation and a perspective term
//     (the classic `m[3][2] = -1/depth` projection) for cards and flips.
//   * Null Object propagation: [TransformMatrixEngine.resolveWorld] walks the
//     parent chain and multiplies `parentWorld * childLocal`, so children
//     inherit the *rotated and scaled* parent space. This is the authoritative
//     composition used for painting; the additive value-level
//     [LayerTransform.compose] remains the cheap approximation used by
//     Module 1 hit-testing.
//   * Adjustment layers: [AdjustmentResolver] aggregates the effects of every
//     adjustment layer sitting above a layer in the stack and hands the result
//     down to that layer.
//
// Buffer discipline: every hot-path API writes into a caller-owned [Matrix4]
// ("...Into" suffix). No matrix is allocated per frame, so a 60 FPS playback
// pass produces zero matrix garbage on 2 GB devices.
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Matrix4;

import '../models/layer_model.dart';

// -----------------------------------------------------------------------------
// Matrix engine
// -----------------------------------------------------------------------------

/// Stateless matrix calculator. Safe to share: all state lives in the caller's
/// buffers, which makes it equally usable from a painter and from a background
/// render worker.
class TransformMatrixEngine {
  const TransformMatrixEngine();

  static const double _degToRad = 0.017453292519943295; // pi / 180

  /// Writes the 2D transform into [out] (reused by the caller every frame).
  ///
  /// Order matters: translate -> rotate -> scale, so scaling is applied first
  /// to the geometry and rotation happens in (scaled) parent space. When
  /// [anchorX]/[anchorY] are non-zero, rotation and scale pivot around that
  /// point in the layer's local space.
  Matrix4 composeInto(
    Matrix4 out,
    LayerTransform transform, {
    double anchorX = 0.0,
    double anchorY = 0.0,
  }) {
    out.setIdentity();

    final position = transform.position;
    final rotationRadians = transform.rotation.radians;
    final scaleX = transform.scale.x;
    final scaleY = transform.scale.y;
    final hasAnchor = anchorX != 0.0 || anchorY != 0.0;

    if (hasAnchor) {
      out.translate(position.x + anchorX, position.y + anchorY);
    } else {
      out.translate(position.x, position.y);
    }
    if (rotationRadians != 0.0) out.rotateZ(rotationRadians);
    if (scaleX != 1.0 || scaleY != 1.0) out.scale(scaleX, scaleY);
    if (hasAnchor) out.translate(-anchorX, -anchorY);
    return out;
  }

  /// Writes the 3D transform into [out]. `perspectiveDistance > 0` enables the
  /// projective term used by Flutter's `Matrix4` transform pipeline.
  Matrix4 compose3DInto(
    Matrix4 out,
    LayerTransform transform, {
    double translateZ = 0.0,
    double rotationXDegrees = 0.0,
    double rotationYDegrees = 0.0,
    double perspectiveDistance = 0.0,
  }) {
    out.setIdentity();
    if (perspectiveDistance > 0.0) {
      out.setEntry(3, 2, -1.0 / perspectiveDistance);
    }
    out.translate(transform.position.x, transform.position.y, translateZ);
    if (rotationYDegrees != 0.0) out.rotateY(rotationYDegrees * _degToRad);
    if (rotationXDegrees != 0.0) out.rotateX(rotationXDegrees * _degToRad);
    final rotationRadians = transform.rotation.radians;
    if (rotationRadians != 0.0) out.rotateZ(rotationRadians);
    out.scale(transform.scale.x, transform.scale.y, 1.0);
    return out;
  }

  /// Allocating convenience wrapper. Do not call inside a paint/tick loop -
  /// use [composeInto] with a cached buffer instead.
  Matrix4 compose(
    LayerTransform transform, {
    double anchorX = 0.0,
    double anchorY = 0.0,
  }) =>
      composeInto(
        Matrix4.identity(),
        transform,
        anchorX: anchorX,
        anchorY: anchorY,
      );

  /// `out = parent * child`. Handy for callers that keep their own buffers.
  Matrix4 multiplyInto(Matrix4 out, Matrix4 parent, Matrix4 child) {
    out.setFrom(parent);
    out.multiply(child);
    return out;
  }

  /// Fully composed world matrix of [layer]: local transform multiplied by
  /// every Null Object ancestor, outermost parent first.
  ///
  /// [localTransformOf] must return the keyframe-resolved local transform of a
  /// layer; [parentOf] resolves the parent link. The walk is depth-guarded so a
  /// corrupted project file cannot hang the renderer.
  ///
  /// Convenience/offline API: it allocates one [Matrix4] per ancestor. For
  /// per-frame playback use the buffer-reusing frame cache in
  /// AnimationPlaybackController instead.
  Matrix4 resolveWorld(
    Layer layer, {
    required LayerTransform Function(Layer layer) localTransformOf,
    required Layer? Function(Layer layer) parentOf,
    int maxDepth = 64,
  }) {
    final local = compose(localTransformOf(layer));
    if (maxDepth <= 0) return local;
    final parent = parentOf(layer);
    if (parent == null) return local;
    final parentWorld = resolveWorld(
      parent,
      localTransformOf: localTransformOf,
      parentOf: parentOf,
      maxDepth: maxDepth - 1,
    );
    final world = parentWorld.clone()..multiply(local);
    return world;
  }
}

// -----------------------------------------------------------------------------
// Adjustment layers
// -----------------------------------------------------------------------------

/// Visual parameters an adjustment layer hands down to every layer below it in
/// the stacking order.
///
/// Deliberately small and additive/multiplicative so the effects pipeline can
/// grow without breaking saved projects: every new field must default to its
/// neutral value. The actual pixel work (blur, colour) arrives with the
/// rendering module; the engine only aggregates the parameters here.
@immutable
class AdjustmentEffect {
  const AdjustmentEffect({
    this.opacityMultiplier = 1.0,
    this.blurSigma = 0.0,
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.temperature = 0.0,
  });

  /// Neutral element: applying it changes nothing.
  static const AdjustmentEffect neutral = AdjustmentEffect();

  /// 1.0 = untouched; multiplies the layer opacity.
  final double opacityMultiplier;

  /// Gaussian sigma in canvas units; 0 = no blur.
  final double blurSigma;

  /// Additive luminance offset, -1.0 .. 1.0.
  final double brightness;

  /// 1.0 = untouched.
  final double contrast;

  /// 1.0 = untouched, 0.0 = greyscale.
  final double saturation;

  /// -1.0 (cool) .. 1.0 (warm).
  final double temperature;

  bool get isNeutral =>
      opacityMultiplier == 1.0 &&
      blurSigma == 0.0 &&
      brightness == 0.0 &&
      contrast == 1.0 &&
      saturation == 1.0 &&
      temperature == 0.0;

  /// Applies [inner] first, then this effect on top.
  AdjustmentEffect combine(AdjustmentEffect inner) => AdjustmentEffect(
        opacityMultiplier: opacityMultiplier * inner.opacityMultiplier,
        blurSigma: blurSigma + inner.blurSigma,
        brightness:
            (brightness + inner.brightness).clamp(-1.0, 1.0).toDouble(),
        contrast: contrast * inner.contrast,
        saturation: saturation * inner.saturation,
        temperature:
            (temperature + inner.temperature).clamp(-1.0, 1.0).toDouble(),
      );

  AdjustmentEffect copyWith({
    double? opacityMultiplier,
    double? blurSigma,
    double? brightness,
    double? contrast,
    double? saturation,
    double? temperature,
  }) =>
      AdjustmentEffect(
        opacityMultiplier: opacityMultiplier ?? this.opacityMultiplier,
        blurSigma: blurSigma ?? this.blurSigma,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        temperature: temperature ?? this.temperature,
      );

  @override
  bool operator ==(Object other) =>
      other is AdjustmentEffect &&
      other.opacityMultiplier == opacityMultiplier &&
      other.blurSigma == blurSigma &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.temperature == temperature;

  @override
  int get hashCode => Object.hash(opacityMultiplier, blurSigma, brightness,
      contrast, saturation, temperature);

  @override
  String toString() => 'AdjustmentEffect(opacity: $opacityMultiplier, '
      'blur: $blurSigma, brightness: $brightness, contrast: $contrast, '
      'saturation: $saturation, temperature: $temperature)';
}

/// Mutable accumulator used once per frame and per affected layer.
///
/// `reset()` + repeated [combine] reuse a single instance instead of building
/// an [AdjustmentEffect] chain, keeping the adjustment pass allocation-free.
class AdjustmentAggregate {
  AdjustmentAggregate();

  double opacityMultiplier = 1.0;
  double blurSigma = 0.0;
  double brightness = 0.0;
  double contrast = 1.0;
  double saturation = 1.0;
  double temperature = 0.0;

  bool get isNeutral =>
      opacityMultiplier == 1.0 &&
      blurSigma == 0.0 &&
      brightness == 0.0 &&
      contrast == 1.0 &&
      saturation == 1.0 &&
      temperature == 0.0;

  void reset() {
    opacityMultiplier = 1.0;
    blurSigma = 0.0;
    brightness = 0.0;
    contrast = 1.0;
    saturation = 1.0;
    temperature = 0.0;
  }

  void combine(AdjustmentEffect effect) {
    opacityMultiplier *= effect.opacityMultiplier;
    blurSigma += effect.blurSigma;
    brightness = (brightness + effect.brightness).clamp(-1.0, 1.0).toDouble();
    contrast *= effect.contrast;
    saturation *= effect.saturation;
    temperature =
        (temperature + effect.temperature).clamp(-1.0, 1.0).toDouble();
  }

  /// Copies [other] into this instance (used by per-layer frame caches).
  void copyFrom(AdjustmentAggregate other) {
    opacityMultiplier = other.opacityMultiplier;
    blurSigma = other.blurSigma;
    brightness = other.brightness;
    contrast = other.contrast;
    saturation = other.saturation;
    temperature = other.temperature;
  }

  AdjustmentEffect toEffect() => AdjustmentEffect(
        opacityMultiplier: opacityMultiplier,
        blurSigma: blurSigma,
        brightness: brightness,
        contrast: contrast,
        saturation: saturation,
        temperature: temperature,
      );

  @override
  String toString() => 'AdjustmentAggregate(opacity: $opacityMultiplier, '
      'blur: $blurSigma, brightness: $brightness, contrast: $contrast, '
      'saturation: $saturation, temperature: $temperature)';
}

/// Owns the adjustment effect assigned to each adjustment layer and resolves,
/// once per frame, the aggregate inherited by every layer.
///
/// Stacking rule (After Effects semantics): an adjustment layer affects the
/// layers *below* it. The controller's list has index 0 at the bottom, so a
/// layer at index `i` inherits every active adjustment whose stack index is
/// greater than `i`.
class AdjustmentResolver {
  AdjustmentResolver();

  final Map<String, AdjustmentEffect> _effects = <String, AdjustmentEffect>{};
  final List<_ActiveAdjustment> _active = <_ActiveAdjustment>[];
  final AdjustmentAggregate _scratch = AdjustmentAggregate();
  int _activeCount = 0;

  // -- effect registry --------------------------------------------------------

  void setEffect(String layerId, AdjustmentEffect effect) {
    if (effect.isNeutral) {
      _effects.remove(layerId);
    } else {
      _effects[layerId] = effect;
    }
  }

  void clearEffect(String layerId) => _effects.remove(layerId);

  AdjustmentEffect effectOf(String layerId) =>
      _effects[layerId] ?? AdjustmentEffect.neutral;

  bool hasEffect(String layerId) => _effects.containsKey(layerId);

  void clearAll() => _effects.clear();

  Map<String, AdjustmentEffect> get effectsById =>
      Map<String, AdjustmentEffect>.unmodifiable(_effects);

  // -- per-frame stack --------------------------------------------------------

  /// Frame pass 1: forget the previous frame's stack (no allocation).
  void beginFrame() => _activeCount = 0;

  /// Frame pass 1: registers a currently-active adjustment layer.
  void register({required String layerId, required int stackIndex}) {
    if (_activeCount < _active.length) {
      final entry = _active[_activeCount];
      entry.layerId = layerId;
      entry.stackIndex = stackIndex;
    } else {
      _active.add(_ActiveAdjustment(layerId, stackIndex));
    }
    _activeCount++;
  }

  bool get hasActiveAdjustments => _activeCount > 0;

  /// Aggregate inherited by the layer at [stackIndex].
  ///
  /// The result is a shared scratch buffer, valid until the next call. Copy it
  /// (`state.effects.copyFrom(resolver.aggregateFor(i))`) when it must outlive
  /// the call, as the per-layer frame cache does.
  AdjustmentAggregate aggregateFor(int stackIndex) {
    _scratch.reset();
    for (var i = 0; i < _activeCount; i++) {
      final active = _active[i];
      if (active.stackIndex <= stackIndex) continue;
      final effect = _effects[active.layerId];
      if (effect != null) _scratch.combine(effect);
    }
    return _scratch;
  }
}

/// Reused entry describing one active adjustment layer in the current frame.
class _ActiveAdjustment {
  _ActiveAdjustment(this.layerId, this.stackIndex);

  String layerId;
  int stackIndex;
}
