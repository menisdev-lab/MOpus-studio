// =============================================================================
// MOpus Studio - lib/engine/motion_blur_processor.dart
// -----------------------------------------------------------------------------
// Velocity-based motion blur (Module 2), tuned for 2 GB devices.
//
// Principle: real camera blur is temporal averaging over an open shutter. A
// dedicated motion-blur render pass would need extra render targets and GPU
// reads; instead this engine converts a layer's per-frame *velocity vector*
// into a small set of transform sample offsets, and the compositor simply
// draws the layer N times at `1/N` alpha, each sample nudged along the motion
// path. Cost scales with the number of *fast* layers, never with resolution.
//
//   * [MotionVelocityEstimator] - smoothed per-second deltas of world position
//     / rotation / scale. Jitter-free smear, zero allocation per frame.
//   * [MotionBlurPlan] - fixed-capacity sample buffers, written in place.
//   * [MotionBlurProcessor] - decides *whether* to blur (thresholds) and *how
//     many* samples to emit, capped by [DeviceTier].
//
// Plain Dart (no Flutter imports) so the engine is unit-testable and reusable
// by an offline export worker.
// =============================================================================

import 'dart:math' as math;
import 'dart:typed_data';

// -----------------------------------------------------------------------------
// Device budget
// -----------------------------------------------------------------------------

/// Device capability budget. Sample caps are deliberately low: three extra
/// draws of a full-screen layer already read as convincing smear on a phone,
/// and the cap protects the 2 GB memory/GPU budget.
enum DeviceTier {
  low(3),
  balanced(5),
  high(8);

  const DeviceTier(this.maxBlurSamples);

  /// Maximum samples per layer, including the sharp current one.
  final int maxBlurSamples;
}

// -----------------------------------------------------------------------------
// Velocity estimation
// -----------------------------------------------------------------------------

/// Tracks one layer's world-space motion between frames.
///
/// Feed it every rendered frame with the layer's resolved world position,
/// rotation and scale. It keeps the previous sample and maintains a smoothed
/// velocity in units (or degrees / relative scale) per second. Call [reset]
/// whenever time jumps discontinuously (seek, loop, clip edit) so a stale
/// velocity can never smear a static frame.
class MotionVelocityEstimator {
  MotionVelocityEstimator({this.smoothing = 0.5})
      : assert(
          smoothing > 0.0 && smoothing <= 1.0,
          'smoothing must be in (0,1]',
        );

  /// EMA factor for each instantaneous velocity: 1.0 = raw, lower = steadier.
  /// 0.5 halves old motion every frame - enough to hide keyframe easing steps
  /// without lagging behind fast whips. The first measured delta is taken
  /// verbatim, so blur kicks in on the very first fast frame.
  final double smoothing;

  double _velocityX = 0.0;
  double _velocityY = 0.0;
  double _angularVelocity = 0.0;
  double _scaleVelocity = 0.0;

  double _previousX = 0.0;
  double _previousY = 0.0;
  double _previousRotation = 0.0;
  double _previousScale = 1.0;
  bool _hasPrevious = false;
  bool _hasVelocity = false;

  /// True once at least one frame sample has been fed.
  bool get hasSample => _hasPrevious;

  double get velocityX => _velocityX;
  double get velocityY => _velocityY;

  /// Degrees per second.
  double get angularVelocity => _angularVelocity;

  /// Relative scale change per second (0.5 = grows 50% per second).
  double get scaleVelocity => _scaleVelocity;

  /// Linear speed in canvas units per second.
  double get speed =>
      math.sqrt(_velocityX * _velocityX + _velocityY * _velocityY);

  void reset() {
    _velocityX = 0.0;
    _velocityY = 0.0;
    _angularVelocity = 0.0;
    _scaleVelocity = 0.0;
    _hasPrevious = false;
    _hasVelocity = false;
  }

  /// Feeds the current frame. [dt] is the time since the previous sample, in
  /// seconds; a non-positive value only re-anchors the previous sample (the
  /// paused/scrubbed case, where no blur must be generated).
  void update({
    required double dt,
    required double x,
    required double y,
    required double rotationDegrees,
    required double scale,
  }) {
    if (!_hasPrevious || dt <= 0.0) {
      _previousX = x;
      _previousY = y;
      _previousRotation = rotationDegrees;
      _previousScale = scale;
      _hasPrevious = true;
      return;
    }

    final instantX = (x - _previousX) / dt;
    final instantY = (y - _previousY) / dt;
    final instantAngular = (rotationDegrees - _previousRotation) / dt;
    final reference =
        _previousScale.abs() < 1e-6 ? 1e-6 : _previousScale.abs();
    final instantScale = (scale - _previousScale) / reference / dt;

    if (!_hasVelocity) {
      // First measured delta: adopt it verbatim (no ramp-up underestimation).
      _velocityX = instantX;
      _velocityY = instantY;
      _angularVelocity = instantAngular;
      _scaleVelocity = instantScale;
      _hasVelocity = true;
    } else {
      _velocityX += (instantX - _velocityX) * smoothing;
      _velocityY += (instantY - _velocityY) * smoothing;
      _angularVelocity += (instantAngular - _angularVelocity) * smoothing;
      _scaleVelocity += (instantScale - _scaleVelocity) * smoothing;
    }

    _previousX = x;
    _previousY = y;
    _previousRotation = rotationDegrees;
    _previousScale = scale;
  }
}

// -----------------------------------------------------------------------------
// Blur plan
// -----------------------------------------------------------------------------

/// Pre-allocated sample set describing how to smear one layer on this frame.
///
/// Sample `i` is the transform variant the compositor draws:
///   * screen-space offset `(dxAt(i), dyAt(i))` in canvas units;
///   * extra rotation `rotationAt(i)` degrees;
///   * centre-based scale multiplier `scaleAt(i)`.
///
/// The last sample is the sharp "now" transform; earlier samples trail behind
/// along the motion path. Draw each sample with [sampleWeight] alpha. Buffers
/// are typed lists allocated once per layer and rewritten in place, so an
/// active blur adds draws but no garbage collection pressure.
class MotionBlurPlan {
  MotionBlurPlan({int capacity = 8})
      : assert(capacity >= 2, 'motion blur needs at least 2 samples'),
        _dx = Float32List(capacity),
        _dy = Float32List(capacity),
        _dRotation = Float32List(capacity),
        _dScale = Float32List(capacity);

  final Float32List _dx;
  final Float32List _dy;
  final Float32List _dRotation;
  final Float32List _dScale;

  int _sampleCount = 0;
  double _blurSigma = 0.0;

  /// 0 = inactive (draw once, sharp); otherwise >= 2 samples.
  int get sampleCount => _sampleCount;

  bool get isActive => _sampleCount > 0;

  /// Suggested directional blur strength in canvas units, for painters that
  /// fall back to a cheap `ImageFilter` instead of multi-sampling.
  double get blurSigma => _blurSigma;

  /// Alpha to use for every sample while the plan is active.
  double get sampleWeight => _sampleCount == 0 ? 1.0 : 1.0 / _sampleCount;

  double dxAt(int index) => _dx[index];

  double dyAt(int index) => _dy[index];

  double rotationAt(int index) => _dRotation[index];

  double scaleAt(int index) => _dScale[index];

  /// Deactivates the plan. Buffers are intentionally left untouched - a stale
  /// value is never read while [sampleCount] is 0.
  void clear() {
    _sampleCount = 0;
    _blurSigma = 0.0;
  }

  @override
  String toString() => isActive
      ? 'MotionBlurPlan(${_sampleCount} samples, sigma ${_blurSigma.toStringAsFixed(1)})'
      : 'MotionBlurPlan(inactive)';
}

// -----------------------------------------------------------------------------
// Processor
// -----------------------------------------------------------------------------

/// Decides and generates smear samples for one layer.
///
/// Thresholds are expressed in canvas units (1920x1080 design space) per
/// second; a layer must exceed at least one of them before a single extra draw
/// happens. `enabled: false` turns the whole pass off (battery saver / quality
/// menu), and [tier] caps the sample count for the device class.
class MotionBlurProcessor {
  const MotionBlurProcessor({
    this.tier = DeviceTier.low,
    this.enabled = true,
    this.shutterFraction = 0.5,
    this.minSpeed = 140.0,
    this.minAngularVelocity = 90.0,
    this.minScaleVelocity = 0.25,
    this.sampleStepUnits = 6.0,
    this.stepDegrees = 1.5,
    this.stepScale = 0.02,
  }) : assert(
          shutterFraction > 0.0 && shutterFraction <= 1.0,
          'shutterFraction must be in (0,1]',
        );

  /// Device class used for the sample cap.
  final DeviceTier tier;

  /// Master switch for the pass.
  final bool enabled;

  /// Fraction of the frame interval the virtual shutter stays open
  /// (0.5 = classic 180-degree film shutter).
  final double shutterFraction;

  /// Minimum linear speed (units / second) that triggers blur.
  final double minSpeed;

  /// Minimum angular speed (degrees / second) that triggers blur.
  final double minAngularVelocity;

  /// Minimum relative scale speed (1 / second) that triggers blur.
  final double minScaleVelocity;

  /// Travel (units) that buys one extra sample.
  final double sampleStepUnits;

  /// Rotation travel (degrees) that buys one extra sample.
  final double stepDegrees;

  /// Relative scale travel that buys one extra sample.
  final double stepScale;

  int get maxSamples => tier.maxBlurSamples;

  /// Computes the plan for one layer, writing into [plan] in place. The plan is
  /// cleared whenever the layer is not blurring or the pass is disabled.
  void process({
    required MotionVelocityEstimator estimator,
    required MotionBlurPlan plan,
    required double dt,
  }) {
    if (!enabled || dt <= 0.0) {
      plan.clear();
      return;
    }

    final vx = estimator.velocityX;
    final vy = estimator.velocityY;
    final speed = estimator.speed;
    final angular = estimator.angularVelocity;
    final scaleVelocity = estimator.scaleVelocity;

    final blurring = speed >= minSpeed ||
        angular.abs() >= minAngularVelocity ||
        scaleVelocity.abs() >= minScaleVelocity;
    if (!blurring) {
      plan.clear();
      return;
    }

    // Exposure window and the travel within it (the smear length).
    final window = dt * shutterFraction;
    final travel = speed * window;
    final angularTravel = angular.abs() * window;
    final scaleTravel = scaleVelocity.abs() * window;

    var count = 2;
    if (travel > 0.0) {
      count = math.max(count, 2 + (travel / sampleStepUnits).floor());
    }
    if (angularTravel > 0.0) {
      count = math.max(count, 2 + (angularTravel / stepDegrees).floor());
    }
    if (scaleTravel > 0.0) {
      count = math.max(count, 2 + (scaleTravel / stepScale).floor());
    }
    final samples = math.max(2, math.min(count, maxSamples));

    // f goes 1 -> 0: oldest exposure sample first, sharp current frame last.
    final invStep = 1.0 / (samples - 1);
    for (var i = 0; i < samples; i++) {
      final f = 1.0 - i * invStep;
      plan._dx[i] = -vx * window * f;
      plan._dy[i] = -vy * window * f;
      plan._dRotation[i] = -angular * window * f;
      final scaleFactor = 1.0 - scaleVelocity * window * f;
      plan._dScale[i] = scaleFactor <= 0.05 ? 0.05 : scaleFactor;
    }
    plan._sampleCount = samples;

    // Cheap directional-blur hint (half the smear, clamped for tiny kernels).
    final sigma = travel > 0.0 ? travel * 0.5 : 0.0;
    plan._blurSigma = sigma > 24.0 ? 24.0 : sigma;
  }

  @override
  String toString() => 'MotionBlurProcessor(${tier.name}, '
      'shutter $shutterFraction, max ${maxSamples} samples, '
      '${enabled ? 'on' : 'off'})';
}
