// =============================================================================
// MOpus Studio - lib/models/keyframe_model.dart
// -----------------------------------------------------------------------------
// Animation keyframes (Module 1).
//
// A Keyframe pairs a *time* on the project timeline with an arbitrary *value*
// for a named animatable property ("position", "scale", "rotation",
// "opacity", "volume"). Values are interpolated by TimelineController using
// the easing attached to the START of each segment.
// =============================================================================

import 'package:flutter/foundation.dart';

import 'layer_model.dart';

// -----------------------------------------------------------------------------
// Easing
// -----------------------------------------------------------------------------

/// Easing presets. The enum id is the canonical string persisted in projects:
/// "linear", "easeIn", "easeOut", "easeInOut", "hold".
enum KeyframeEasing {
  linear,
  easeIn,
  easeOut,
  easeInOut,

  /// Step/hold: keeps the previous value until the next keyframe.
  hold;

  String get id => name;

  String get label => switch (this) {
        KeyframeEasing.linear => 'Linear',
        KeyframeEasing.easeIn => 'Ease In',
        KeyframeEasing.easeOut => 'Ease Out',
        KeyframeEasing.easeInOut => 'Ease In Out',
        KeyframeEasing.hold => 'Hold',
      };

  static KeyframeEasing parse(Object? raw, [KeyframeEasing fallback = KeyframeEasing.linear]) {
    if (raw is KeyframeEasing) return raw;
    if (raw is String) {
      for (final value in KeyframeEasing.values) {
        if (value.name == raw) return value;
      }
    }
    return fallback;
  }
}

/// Canonical animatable property names. Use these constants instead of raw
/// strings to keep controller/view/model in sync.
abstract final class KeyframeProperty {
  static const String position = 'position';
  static const String scale = 'scale';
  static const String rotation = 'rotation';
  static const String opacity = 'opacity';
  static const String volume = 'volume';

  /// The transform properties auto-keyed by the preview gizmos.
  static const List<String> transform = <String>[position, scale, rotation];
}

// -----------------------------------------------------------------------------
// Keyframe
// -----------------------------------------------------------------------------

/// One animation point: `time` (seconds) -> `value`.
///
/// `value` is dynamic on purpose so a single type can animate scalars
/// (opacity, volume) and vector types (Position, Scale, Rotation) without
/// boxing overhead beyond the cast performed by the evaluator.
@immutable
class Keyframe {
  const Keyframe({
    required this.id,
    required this.propertyName,
    required this.time,
    required this.value,
    this.easingCurve = 'linear',
  });

  /// Typed convenience constructor (preferred API).
  Keyframe.eased({
    required String id,
    required String propertyName,
    required double time,
    required dynamic value,
    KeyframeEasing easing = KeyframeEasing.linear,
  }) : this(
          id: id,
          propertyName: propertyName,
          time: time,
          value: value,
          easingCurve: easing.id,
        );

  final String id;

  /// See [KeyframeProperty].
  final String propertyName;

  /// Position on the project timeline, in seconds.
  final double time;

  /// num | Position | Scale | Rotation (extend [lerpValue] for new types).
  final dynamic value;

  /// Canonical easing id; see [KeyframeEasing].
  final String easingCurve;

  /// Parsed easing.
  KeyframeEasing get easing => KeyframeEasing.parse(easingCurve);

  static const double timeEpsilon = 0.001;

  Keyframe copyWith({
    String? propertyName,
    double? time,
    dynamic value,
    String? easingCurve,
  }) =>
      Keyframe(
        id: id,
        propertyName: propertyName ?? this.propertyName,
        time: time ?? this.time,
        value: value ?? this.value,
        easingCurve: easingCurve ?? this.easingCurve,
      );

  Keyframe withEasing(KeyframeEasing easing) => Keyframe(
        id: id,
        propertyName: propertyName,
        time: time,
        value: value,
        easingCurve: easing.id,
      );

  /// True when [other] sits on (practically) the same time.
  bool isAtTime(double other, {double epsilon = timeEpsilon}) =>
      (time - other).abs() <= epsilon;

  // ---------------------------------------------------------------------------
  // Interpolation
  // ---------------------------------------------------------------------------

  /// Interpolates between two keyframe values. `t` is already eased (0..1).
  /// Unknown/mismatched types fall back to a hold behaviour so evaluation can
  /// never throw on corrupt project files.
  static dynamic lerpValue(dynamic a, dynamic b, double t) {
    if (a == null) return b;
    if (b == null) return a;
    if (a is num && b is num) return a + (b - a) * t;
    if (a is Position && b is Position) return Position.lerp(a, b, t);
    if (a is Scale && b is Scale) return Scale.lerp(a, b, t);
    if (a is Rotation && b is Rotation) return Rotation.lerp(a, b, t);
    return t < 1.0 ? a : b;
  }

  // ---------------------------------------------------------------------------
  // Ordering / equality / serialization
  // ---------------------------------------------------------------------------

  /// Ascending time order (used when sorting keyframe tracks).
  static int compare(Keyframe a, Keyframe b) => a.time.compareTo(b.time);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'propertyName': propertyName,
        'time': time,
        'value': _encodeValue(value),
        'easingCurve': easingCurve,
      };

  static Keyframe fromJson(Map<String, dynamic> json) => Keyframe(
        id: json['id'] is String ? json['id'] as String : 'kf_unknown',
        propertyName:
            json['propertyName'] is String ? json['propertyName'] as String : KeyframeProperty.opacity,
        time: _asDouble(json['time']),
        value: _decodeValue(json['value']),
        easingCurve: json['easingCurve'] is String
            ? json['easingCurve'] as String
            : KeyframeEasing.linear.id,
      );

  @override
  bool operator ==(Object other) =>
      other is Keyframe &&
      other.id == id &&
      other.propertyName == propertyName &&
      other.time == time &&
      _valuesEqual(other.value, value) &&
      other.easingCurve == easingCurve;

  @override
  int get hashCode =>
      Object.hash(id, propertyName, time, easingCurve, value is Object ? value : 0);

  @override
  String toString() =>
      'Keyframe($id, $propertyName, ${time.toStringAsFixed(3)}s -> $value, $easingCurve)';
}

// -----------------------------------------------------------------------------
// Value (de)serialization + equality helpers
// -----------------------------------------------------------------------------

Object? _encodeValue(Object? value) {
  if (value is num || value == null) return value;
  if (value is Position) {
    return <String, dynamic>{'__type': 'position', ...value.toJson()};
  }
  if (value is Scale) {
    return <String, dynamic>{'__type': 'scale', ...value.toJson()};
  }
  if (value is Rotation) {
    return <String, dynamic>{'__type': 'rotation', ...value.toJson()};
  }
  return value.toString();
}

Object? _decodeValue(Object? raw) {
  if (raw is num || raw == null) return raw;
  if (raw is Map) {
    final map = Map<String, dynamic>.from(raw);
    return switch (map['__type']) {
      'position' => Position.fromJson(map),
      'scale' => Scale.fromJson(map),
      'rotation' => Rotation.fromJson(map),
      _ => null,
    };
  }
  if (raw is String) return double.tryParse(raw) ?? raw;
  return raw;
}

bool _valuesEqual(Object? a, Object? b) {
  if (a == b) return true;
  if (a is num && b is num) return a == b;
  return false;
}

double _asDouble(Object? raw, [double fallback = 0.0]) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw) ?? fallback;
  return fallback;
}
