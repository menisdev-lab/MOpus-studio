// =============================================================================
// MOpus Studio - lib/engine/animation_interpolator.dart
// -----------------------------------------------------------------------------
// Keyframe interpolation core (Module 2).
//
//   * Easing: Linear, EaseIn, EaseOut, EaseInOut, plus custom cubic-Bezier
//     handles. Custom curves persist as `cubic(x1,y1,x2,y2)` strings inside the
//     existing Keyframe.easingCurve field (Module 1) - no schema change - and
//     are resolved lazily into a real [Cubic] curve.
//   * Sampling: O(log n) binary search over an already-sorted track, or O(1)
//     amortized with a reusable [TrackCursor]. Playback advances one segment at
//     a time, which is exactly the 60 FPS scrub case.
//   * Exact interpolated values for Position / Scale / Rotation / num
//     (opacity, volume, ...).
//
// Allocation notes (2 GB device budget):
//   * preset curves are `const` and shared;
//   * every distinct easing string is parsed once into a cached [EasingSpec],
//     so the hot path does no Cubic construction, list building or parsing;
//   * the only per-sample allocation is the small immutable value object the
//     domain model requires (Position / Scale / Rotation).
// =============================================================================

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

import '../models/keyframe_model.dart';
import '../models/layer_model.dart';

// -----------------------------------------------------------------------------
// Custom Bezier handles
// -----------------------------------------------------------------------------

/// Control points of a CSS-style cubic-Bezier easing:
/// `P0 = (0,0)`, `P1 = (x1,y1)`, `P2 = (x2,y2)`, `P3 = (1,1)`.
///
/// X coordinates are clamped to `[0,1]` so the curve stays a function of time;
/// Y may overshoot (anticipation / bounce), exactly like professional NLEs.
@immutable
class CubicBezierHandles {
  const CubicBezierHandles(this.x1, this.y1, this.x2, this.y2);

  /// Smooth deceleration; a good default for title/UI motion.
  static const CubicBezierHandles easeOutSoft =
      CubicBezierHandles(0.25, 0.1, 0.25, 1.0);

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  /// Same handles with X forced into the legal time range.
  CubicBezierHandles normalized() => CubicBezierHandles(
        x1.clamp(0.0, 1.0).toDouble(),
        y1,
        x2.clamp(0.0, 1.0).toDouble(),
        y2,
      );

  /// Allocates a new [Cubic]. Fine for one-off use (widgets, tests); hot paths
  /// should sample through [EasingSpec], which caches the resolved curve.
  Curve toCurve() {
    final n = normalized();
    return Cubic(n.x1, n.y1, n.x2, n.y2);
  }

  /// Compact persistence form understood by [EasingSpec.parse].
  String toEasingString() => 'cubic($x1, $y1, $x2, $y2)';

  @override
  bool operator ==(Object other) =>
      other is CubicBezierHandles &&
      other.x1 == x1 &&
      other.y1 == y1 &&
      other.x2 == x2 &&
      other.y2 == y2;

  @override
  int get hashCode => Object.hash(x1, y1, x2, y2);

  @override
  String toString() => 'CubicBezierHandles($x1, $y1, $x2, $y2)';
}

// -----------------------------------------------------------------------------
// Easing specification
// -----------------------------------------------------------------------------

/// A resolved easing definition: either a named preset ("linear", "easeIn",
/// "easeOut", "easeInOut", "hold") or custom cubic-Bezier handles.
///
/// Instances are created through [parse] (bounded cache) or the preset statics.
/// The underlying [Curve] is built lazily, exactly once per instance, so a
/// project using four easings allocates four curves in total.
class EasingSpec {
  EasingSpec.preset(this._easing) : _handles = null;

  EasingSpec.bezier(this._handles) : _easing = KeyframeEasing.linear;

  final KeyframeEasing _easing;
  final CubicBezierHandles? _handles;

  late final Curve _curve = _resolve();

  // -- shared presets ---------------------------------------------------------

  static final EasingSpec linear = EasingSpec.preset(KeyframeEasing.linear);
  static final EasingSpec easeIn = EasingSpec.preset(KeyframeEasing.easeIn);
  static final EasingSpec easeOut = EasingSpec.preset(KeyframeEasing.easeOut);
  static final EasingSpec easeInOut =
      EasingSpec.preset(KeyframeEasing.easeInOut);
  static final EasingSpec hold = EasingSpec.preset(KeyframeEasing.hold);

  /// Parse cache: real projects use a handful of easing strings at most.
  static final Map<String, EasingSpec> _cache = <String, EasingSpec>{};
  static const int _maxCacheEntries = 64;

  // -- inspection -------------------------------------------------------------

  bool get isStep => _handles == null && _easing == KeyframeEasing.hold;

  bool get isCustomBezier => _handles != null;

  CubicBezierHandles? get handles => _handles;

  KeyframeEasing get easing => _easing;

  /// Canonical persistence string: "easeInOut", "cubic(0.4,0,0.2,1)", ...
  String get easingString {
    final h = _handles;
    if (h != null) return h.toEasingString();
    return _easing.id;
  }

  // -- evaluation -------------------------------------------------------------

  /// Eased progress in `[0,1]` for a linear segment progress [t].
  ///
  /// A "hold" step returns `0.0`, which keeps the value of the *start*
  /// keyframe until the next keyframe begins - identical to the behaviour
  /// TimelineController exposed in Module 1.
  double transform(double t) {
    final clamped = t <= 0.0 ? 0.0 : (t >= 1.0 ? 1.0 : t);
    if (isStep) return 0.0;
    return _curve.transform(clamped);
  }

  Curve _resolve() {
    final h = _handles;
    if (h != null) {
      final n = h.normalized();
      return Cubic(n.x1, n.y1, n.x2, n.y2);
    }
    return switch (_easing) {
      KeyframeEasing.linear => Curves.linear,
      KeyframeEasing.easeIn => Curves.easeIn,
      KeyframeEasing.easeOut => Curves.easeOut,
      KeyframeEasing.easeInOut => Curves.easeInOut,
      KeyframeEasing.hold => Curves.linear, // step handled in transform()
    };
  }

  // -- parsing ----------------------------------------------------------------

  /// Parses a persisted easing string. Unknown values fall back to linear.
  /// Custom curves use CSS syntax: `cubic(x1, y1, x2, y2)`.
  static EasingSpec parse(String raw) {
    if (raw.isEmpty) return linear;
    final cached = _cache[raw];
    if (cached != null) return cached;
    final spec = _parseUncached(raw);
    if (_cache.length >= _maxCacheEntries) _cache.clear();
    _cache[raw] = spec;
    return spec;
  }

  static EasingSpec presetFor(KeyframeEasing easing) => switch (easing) {
        KeyframeEasing.linear => linear,
        KeyframeEasing.easeIn => easeIn,
        KeyframeEasing.easeOut => easeOut,
        KeyframeEasing.easeInOut => easeInOut,
        KeyframeEasing.hold => hold,
      };

  static EasingSpec _parseUncached(String raw) {
    final lower = raw.trim().toLowerCase();
    if (lower.startsWith('cubic(') && lower.endsWith(')')) {
      final inner = lower.substring(6, lower.length - 1);
      final parts = inner.split(',');
      if (parts.length == 4) {
        final x1 = double.tryParse(parts[0].trim());
        final y1 = double.tryParse(parts[1].trim());
        final x2 = double.tryParse(parts[2].trim());
        final y2 = double.tryParse(parts[3].trim());
        if (x1 != null && y1 != null && x2 != null && y2 != null) {
          return EasingSpec.bezier(CubicBezierHandles(x1, y1, x2, y2));
        }
      }
      return linear;
    }
    return presetFor(KeyframeEasing.parse(lower));
  }

  @override
  String toString() => 'EasingSpec($easingString)';
}

// -----------------------------------------------------------------------------
// Interpolator
// -----------------------------------------------------------------------------

/// Pure, allocation-conscious keyframe sampler.
///
/// Every member is static: the interpolator itself owns no state, so several
/// controllers, timeline thumbnails or offline workers can share it without
/// interference. Reusable per-track state lives in [TrackCursor].
abstract final class AnimationInterpolator {
  /// Index of the segment start for [time]: the last keyframe whose time is
  /// `<= time` (binary search, O(log n)). Returns 0 for empty tracks.
  static int segmentIndex(List<Keyframe> track, double time) {
    if (track.isEmpty) return 0;
    var low = 0;
    var high = track.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (track[mid].time <= time) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// Linear (un-eased) progress in `[0,1]` inside the segment starting at
  /// [index]. Safe for out-of-range indices and zero-length segments.
  static double rawProgress(List<Keyframe> track, int index, double time) {
    if (track.isEmpty) return 0.0;
    final safeIndex =
        index < 0 ? 0 : (index >= track.length ? track.length - 1 : index);
    final a = track[safeIndex];
    if (safeIndex >= track.length - 1) return 1.0;
    final b = track[safeIndex + 1];
    final span = b.time - a.time;
    if (span <= 0.0) return 1.0;
    final raw = (time - a.time) / span;
    return raw <= 0.0 ? 0.0 : (raw >= 1.0 ? 1.0 : raw);
  }

  /// Exact value between two surrounding keyframes at [time].
  ///
  /// Segment easing always comes from the *start* keyframe ([a]) - the same
  /// convention as Module 1 and mainstream NLEs.
  static dynamic between(Keyframe a, Keyframe b, double time) {
    final span = b.time - a.time;
    if (span <= 0.0) return b.value;
    final raw = (time - a.time) / span;
    final eased = EasingSpec.parse(a.easingCurve).transform(raw);
    if (eased <= 0.0) return a.value; // exact ends: skip the lerp allocation
    if (eased >= 1.0) return b.value;
    return Keyframe.lerpValue(a.value, b.value, eased);
  }

  /// Samples a time-sorted track. Returns `null` when [track] is null or empty
  /// so callers fall back to the static property value.
  static dynamic sample(List<Keyframe>? track, double time) {
    if (track == null || track.isEmpty) return null;
    final first = track.first;
    if (time <= first.time) return first.value;
    final last = track.last;
    if (time >= last.time) return last.value;
    final index = segmentIndex(track, time);
    if (index >= track.length - 1) return last.value;
    return between(track[index], track[index + 1], time);
  }

  // -- typed accessors --------------------------------------------------------

  static Position? positionAt(List<Keyframe>? track, double time) {
    final value = sample(track, time);
    return value is Position ? value : null;
  }

  static Scale? scaleAt(List<Keyframe>? track, double time) {
    final value = sample(track, time);
    return value is Scale ? value : null;
  }

  static Rotation? rotationAt(List<Keyframe>? track, double time) {
    final value = sample(track, time);
    return value is Rotation ? value : null;
  }

  static double? numberAt(List<Keyframe>? track, double time) {
    final value = sample(track, time);
    return value is num ? value.toDouble() : null;
  }

  // -- composed helpers -------------------------------------------------------

  /// Resolves a full local transform from per-property tracks. Empty tracks
  /// leave the corresponding part of [base] untouched.
  static LayerTransform transformAt({
    required LayerTransform base,
    required double time,
    List<Keyframe>? positionTrack,
    List<Keyframe>? scaleTrack,
    List<Keyframe>? rotationTrack,
  }) {
    var transform = base;
    final position = positionAt(positionTrack, time);
    if (position != null) transform = transform.copyWith(position: position);
    final scale = scaleAt(scaleTrack, time);
    if (scale != null) transform = transform.copyWith(scale: scale.clamped());
    final rotation = rotationAt(rotationTrack, time);
    if (rotation != null) transform = transform.copyWith(rotation: rotation);
    return transform;
  }

  /// Resolves opacity (num track), clamped to `[0,1]`, with [baseOpacity] as
  /// the fallback when the track is empty.
  static double opacityAt(
      double baseOpacity, List<Keyframe>? track, double time) {
    final value = numberAt(track, time) ?? baseOpacity;
    return value <= 0.0 ? 0.0 : (value >= 1.0 ? 1.0 : value);
  }
}

// -----------------------------------------------------------------------------
// Track cursor
// -----------------------------------------------------------------------------

/// Reusable sampling cursor for one (sorted) keyframe track.
///
/// Playback and scrubbing move time monotonically, so the cached segment is
/// almost always the right one: [sampleAt] then costs one comparison instead of
/// a binary search, and allocates no bookkeeping state. Keep one cursor per
/// animated property for the lifetime of the view/worker that owns it.
class TrackCursor {
  TrackCursor(this.track);

  /// The immutable, time-sorted track this cursor samples.
  final List<Keyframe> track;

  int _index = -1;

  /// Cached segment index, `-1` while cold.
  int get segmentIndex => _index;

  /// Samples the track at [time] with an O(1) fast path.
  dynamic sampleAt(double time) {
    if (track.isEmpty) return null;
    if (track.length == 1) return track.first.value;

    var index = _index;
    if (index < 0 || index >= track.length - 1) {
      index = AnimationInterpolator.segmentIndex(track, time);
    } else {
      // Walk at most across neighbouring segments (usually zero steps).
      while (index > 0 && time < track[index].time) {
        index--;
      }
      while (index < track.length - 1 && time >= track[index + 1].time) {
        index++;
      }
    }
    _index = index;
    final a = track[index];
    if (index >= track.length - 1) return a.value;
    return AnimationInterpolator.between(a, track[index + 1], time);
  }

  @override
  String toString() => 'TrackCursor(${track.length} keyframes @ $segmentIndex)';
}
