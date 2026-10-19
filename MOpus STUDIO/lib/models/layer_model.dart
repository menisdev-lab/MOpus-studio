// =============================================================================
// MOpus Studio - lib/models/layer_model.dart
// -----------------------------------------------------------------------------
// Layer Architecture (Module 1, offline-first).
//
// Core domain model of the editor:
//   * [LayerType]      - the six layer kinds supported by the compositor.
//   * [Position]       - 2D translation in project canvas units.
//   * [Scale]          - 2D scale (1.0 = 100%).
//   * [Rotation]       - clockwise rotation in degrees.
//   * [LayerTransform] - immutable bundle of position/scale/rotation.
//   * [Layer]          - a timeline layer (clip) with transform + parenting.
//
// Conventions
//   * Time is expressed in seconds (double) on a global project timeline.
//   * Position (0,0) is the canvas center; +Y points down (screen space).
//   * Layers are plain immutable value objects: all mutations flow through
//     TimelineController so undo/redo/persistence can be added later.
// =============================================================================

import 'package:flutter/foundation.dart';

// -----------------------------------------------------------------------------
// Layer type
// -----------------------------------------------------------------------------

/// The six layer kinds the editor understands.
enum LayerType {
  video,
  audio,
  text,
  shape,
  nullObject,
  adjustmentLayer;

  /// Human readable label for headers, menus and diagnostics.
  String get label => switch (this) {
        LayerType.video => 'Video',
        LayerType.audio => 'Audio',
        LayerType.text => 'Text',
        LayerType.shape => 'Shape',
        LayerType.nullObject => 'Null Object',
        LayerType.adjustmentLayer => 'Adjustment',
      };

  /// True when the layer draws pixels in the preview canvas.
  bool get isVisual => switch (this) {
        LayerType.video => true,
        LayerType.audio => false,
        LayerType.text => true,
        LayerType.shape => true,
        LayerType.nullObject => false, // transform-only helper
        LayerType.adjustmentLayer => true,
      };

  /// True when this layer type can act as a parenting target.
  /// Null objects exist exactly for this purpose (rigging / grouping).
  bool get canParent => this == LayerType.nullObject;

  /// Safe parse used by the (future) project deserializer.
  static LayerType parse(Object? raw) {
    if (raw is LayerType) return raw;
    if (raw is String) {
      for (final value in LayerType.values) {
        if (value.name == raw) return value;
      }
    }
    return LayerType.video;
  }
}

// -----------------------------------------------------------------------------
// Transform value objects
// -----------------------------------------------------------------------------

/// 2D translation, in project canvas units, relative to the canvas center.
@immutable
class Position {
  const Position({this.x = 0.0, this.y = 0.0});

  final double x;
  final double y;

  static const Position zero = Position();

  Position copyWith({double? x, double? y}) =>
      Position(x: x ?? this.x, y: y ?? this.y);

  Position translated(double dx, double dy) => Position(x: x + dx, y: y + dy);

  static Position lerp(Position a, Position b, double t) =>
      Position(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t);

  Map<String, dynamic> toJson() => <String, dynamic>{'x': x, 'y': y};

  static Position fromJson(Map<String, dynamic> json) => Position(
        x: _asDouble(json['x']),
        y: _asDouble(json['y']),
      );

  @override
  bool operator ==(Object other) =>
      other is Position && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Position(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

/// 2D scale factor. 1.0 means "native size".
@immutable
class Scale {
  const Scale({this.x = 1.0, this.y = 1.0});

  const Scale.uniform(double value)
      : x = value,
        y = value;

  final double x;
  final double y;

  static const Scale identity = Scale();
  static const double minValue = 0.01;
  static const double maxValue = 64.0;

  Scale copyWith({double? x, double? y}) => Scale(x: x ?? this.x, y: y ?? this.y);

  /// Clamps both axes into the supported range.
  Scale clamped() => Scale(
        x: x.clamp(minValue, maxValue).toDouble(),
        y: y.clamp(minValue, maxValue).toDouble(),
      );

  static Scale lerp(Scale a, Scale b, double t) =>
      Scale(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t);

  Map<String, dynamic> toJson() => <String, dynamic>{'x': x, 'y': y};

  static Scale fromJson(Map<String, dynamic> json) {
    final fallbackX = _asDouble(json['x'], 1.0);
    final fallbackY = _asDouble(json['y'], 1.0);
    return Scale(
      x: fallbackX == 0 ? 1.0 : fallbackX,
      y: fallbackY == 0 ? 1.0 : fallbackY,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Scale && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Scale(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}

/// Clockwise rotation in degrees (screen space). Radians are derived.
@immutable
class Rotation {
  const Rotation({this.degrees = 0.0});

  final double degrees;

  static const Rotation zero = Rotation();
  static const double _degToRad = 0.017453292519943295; // pi / 180

  double get radians => degrees * _degToRad;

  Rotation copyWith({double? degrees}) => Rotation(degrees: degrees ?? this.degrees);

  static Rotation lerp(Rotation a, Rotation b, double t) =>
      Rotation(degrees: a.degrees + (b.degrees - a.degrees) * t);

  /// Normalizes into (-180, 180].
  Rotation normalized() {
    var d = degrees % 360.0;
    if (d > 180.0) d -= 360.0;
    if (d <= -180.0) d += 360.0;
    return Rotation(degrees: d);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{'degrees': degrees};

  static Rotation fromJson(Map<String, dynamic> json) =>
      Rotation(degrees: _asDouble(json['degrees']));

  @override
  bool operator ==(Object other) => other is Rotation && other.degrees == degrees;

  @override
  int get hashCode => degrees.hashCode;

  @override
  String toString() => 'Rotation(${degrees.toStringAsFixed(1)} deg)';
}

/// Immutable bundle applied to a layer before compositing.
@immutable
class LayerTransform {
  const LayerTransform({
    this.position = Position.zero,
    this.scale = Scale.identity,
    this.rotation = Rotation.zero,
  });

  final Position position;
  final Scale scale;
  final Rotation rotation;

  static const LayerTransform identity = LayerTransform();

  LayerTransform copyWith({
    Position? position,
    Scale? scale,
    Rotation? rotation,
  }) =>
      LayerTransform(
        position: position ?? this.position,
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
      );

  /// Local * Parent composition used for null-object rigging.
  /// Position adds (parent space offset), scale multiplies, rotation adds.
  static LayerTransform compose(LayerTransform parent, LayerTransform child) =>
      LayerTransform(
        position: Position(
          x: parent.position.x + child.position.x,
          y: parent.position.y + child.position.y,
        ),
        scale: Scale(
          x: parent.scale.x * child.scale.x,
          y: parent.scale.y * child.scale.y,
        ),
        rotation: Rotation(
          degrees: parent.rotation.degrees + child.rotation.degrees,
        ),
      );

  static LayerTransform lerp(LayerTransform a, LayerTransform b, double t) =>
      LayerTransform(
        position: Position.lerp(a.position, b.position, t),
        scale: Scale.lerp(a.scale, b.scale, t),
        rotation: Rotation.lerp(a.rotation, b.rotation, t),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'position': position.toJson(),
        'scale': scale.toJson(),
        'rotation': rotation.toJson(),
      };

  static LayerTransform fromJson(Map<String, dynamic> json) => LayerTransform(
        position: Position.fromJson(_asMap(json['position'])),
        scale: Scale.fromJson(_asMap(json['scale'])),
        rotation: Rotation.fromJson(_asMap(json['rotation'])),
      );

  @override
  bool operator ==(Object other) =>
      other is LayerTransform &&
      other.position == position &&
      other.scale == scale &&
      other.rotation == rotation;

  @override
  int get hashCode => Object.hash(position, scale, rotation);

  @override
  String toString() => 'LayerTransform($position, $scale, $rotation)';
}

// -----------------------------------------------------------------------------
// Layer
// -----------------------------------------------------------------------------

/// A single layer/clip on the timeline.
@immutable
class Layer {
  const Layer({
    required this.id,
    required this.name,
    required this.type,
    this.startTime = 0.0,
    this.duration = 5.0,
    this.opacity = 1.0,
    this.transform = LayerTransform.identity,
    this.parentId,
    this.isLocked = false,
    this.isVisible = true,
  });

  /// Stable unique id (generated by the controller).
  final String id;

  /// Display name shown in headers and clips.
  final String name;

  final LayerType type;

  /// Timeline position, in seconds.
  final double startTime;

  /// Clip length, in seconds (> 0).
  final double duration;

  /// 0.0 .. 1.0
  final double opacity;

  /// Local transform (before parenting).
  final LayerTransform transform;

  /// Id of the parent null object, if any (see [TimelineController]).
  final String? parentId;

  final bool isLocked;
  final bool isVisible;

  /// Sentinel allowing `copyWith(parentId: null)` to clear the parent.
  static const Object _unset = Object();

  double get endTime => startTime + duration;

  /// True while [time] is inside the clip. Half-open interval: the clip is
  /// NOT active on its exact end frame (matches NLE convention).
  bool containsTime(double time) => time >= startTime && time < endTime;

  /// True when the layer can appear in the preview at [time].
  bool get isRenderable => type.isVisual;

  Layer copyWith({
    String? name,
    LayerType? type,
    double? startTime,
    double? duration,
    double? opacity,
    LayerTransform? transform,
    Object? parentId = _unset,
    bool? isLocked,
    bool? isVisible,
  }) =>
      Layer(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        startTime: startTime ?? this.startTime,
        duration: duration ?? this.duration,
        opacity: (opacity ?? this.opacity).clamp(0.0, 1.0).toDouble(),
        transform: transform ?? this.transform,
        parentId: identical(parentId, _unset) ? this.parentId : parentId as String?,
        isLocked: isLocked ?? this.isLocked,
        isVisible: isVisible ?? this.isVisible,
      );

  /// Convenience for attaching/detaching a parent null object.
  Layer withParent(String? parentId) => copyWith(parentId: parentId);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'type': type.name,
        'startTime': startTime,
        'duration': duration,
        'opacity': opacity,
        'transform': transform.toJson(),
        'parentId': parentId,
        'isLocked': isLocked,
        'isVisible': isVisible,
      };

  static Layer fromJson(Map<String, dynamic> json) {
    final duration = _asDouble(json['duration'], 5.0);
    return Layer(
      id: _asString(json['id'], 'layer_unknown'),
      name: _asString(json['name'], 'Layer'),
      type: LayerType.parse(json['type']),
      startTime: _asDouble(json['startTime']).clamp(0.0, double.maxFinite).toDouble(),
      duration: duration <= 0 ? 1.0 : duration,
      opacity: _asDouble(json['opacity'], 1.0).clamp(0.0, 1.0).toDouble(),
      transform: LayerTransform.fromJson(_asMap(json['transform'])),
      parentId: json['parentId'] is String ? json['parentId'] as String : null,
      isLocked: json['isLocked'] == true,
      isVisible: json['isVisible'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Layer &&
      other.id == id &&
      other.name == name &&
      other.type == type &&
      other.startTime == startTime &&
      other.duration == duration &&
      other.opacity == opacity &&
      other.transform == transform &&
      other.parentId == parentId &&
      other.isLocked == isLocked &&
      other.isVisible == isVisible;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        type,
        startTime,
        duration,
        opacity,
        transform,
        parentId,
        isLocked,
        isVisible,
      );

  @override
  String toString() =>
      'Layer($id, $name, ${type.name}, ${startTime.toStringAsFixed(2)}s + '
      '${duration.toStringAsFixed(2)}s)';
}

// -----------------------------------------------------------------------------
// Deserialization helpers (tolerant of nulls / stringy numbers)
// -----------------------------------------------------------------------------

double _asDouble(Object? raw, [double fallback = 0.0]) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw) ?? fallback;
  return fallback;
}

String _asString(Object? raw, [String fallback = '']) =>
    raw is String && raw.isNotEmpty ? raw : fallback;

Map<String, dynamic> _asMap(Object? raw) =>
    raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
