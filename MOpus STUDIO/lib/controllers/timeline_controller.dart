// =============================================================================
// MOpus Studio - lib/controllers/timeline_controller.dart
// -----------------------------------------------------------------------------
// TimelineController (Module 1)
//
// Single ChangeNotifier that owns the editable project state:
//   * layer list + z-order (index 0 = bottom of the compositing stack)
//   * playhead position / frame stepping / timecode formatting
//   * selection (shared by the timeline UI and the preview canvas)
//   * keyframe tracks per layer/property + curve evaluation at any time
//   * Null Object parenting: children inherit their parent's transform.
//
// Design notes
//   * Zero external dependencies; layers are immutable value objects and are
//     swapped through this controller so undo/redo or a command bus can be
//     layered on later without touching the UI.
//   * Editing operations respect `Layer.isLocked` and return `false` when a
//     mutation is rejected, so views can react (haptic/toast) if needed.
//   * Auto-keying: once a property has at least one keyframe, gizmo edits on
//     that property are written as keyframes at the playhead instead of the
//     static transform (classic NLE behaviour).
// =============================================================================

import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

import '../models/keyframe_model.dart';
import '../models/layer_model.dart';

class TimelineController extends ChangeNotifier {
  TimelineController({this.frameRate = 30})
      : assert(frameRate > 0, 'frameRate must be positive');

  /// Project frame rate (integer). Used for frame stepping + timecode.
  final int frameRate;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  final List<Layer> _layers = <Layer>[];

  /// layerId -> propertyName -> keyframes (always sorted by time).
  final Map<String, Map<String, List<Keyframe>>> _keyframes =
      <String, Map<String, List<Keyframe>>>{};

  final Map<LayerType, int> _typeCounters = <LayerType, int>{};

  double _playhead = 0.0;
  String? _selectedLayerId;
  int _idSeed = 0;

  // ---------------------------------------------------------------------------
  // Read-only accessors
  // ---------------------------------------------------------------------------

  /// Layers in compositing order: index 0 is painted first (bottom).
  List<Layer> get layers => List<Layer>.unmodifiable(_layers);

  int get layerCount => _layers.length;

  bool get isEmpty => _layers.isEmpty;

  double get playhead => _playhead;

  int get playheadFrame => (_playhead * frameRate).round();

  String? get selectedLayerId => _selectedLayerId;

  Layer? get selectedLayer => layerById(_selectedLayerId);

  /// Total timeline length: the furthest layer end, minimum 0.
  double get projectDuration {
    var maxEnd = 0.0;
    for (final layer in _layers) {
      maxEnd = math.max(maxEnd, layer.endTime);
    }
    return maxEnd;
  }

  Layer? layerById(String? id) {
    if (id == null) return null;
    for (final layer in _layers) {
      if (layer.id == id) return layer;
    }
    return null;
  }

  int indexOfLayer(String id) {
    for (var i = 0; i < _layers.length; i++) {
      if (_layers[i].id == id) return i;
    }
    return -1;
  }

  bool isLayerActiveAt(Layer layer, double time) => layer.containsTime(time);

  /// Candidate times used by snap-to-grid (0s + every layer edge).
  List<double> get snapPoints {
    final points = <double>[0.0];
    for (final layer in _layers) {
      points
        ..add(layer.startTime)
        ..add(layer.endTime);
    }
    return points;
  }

  /// Nearest snap candidate within [tolerance] seconds, or null.
  double? nearestSnapPoint(double time, double tolerance) {
    double? best;
    var bestDistance = tolerance;
    for (final point in snapPoints) {
      final distance = (point - time).abs();
      if (distance <= bestDistance) {
        bestDistance = distance;
        best = point;
      }
    }
    return best;
  }

  // ---------------------------------------------------------------------------
  // Layer creation / removal
  // ---------------------------------------------------------------------------

  /// Appends [layer] on top of the stack (end of the list = top).
  void addLayer(Layer layer) {
    _layers.add(layer);
    notifyListeners();
  }

  /// Builds and adds a layer with sensible defaults for [type].
  /// New layers are dropped at the current playhead.
  Layer addLayerOfType(LayerType type, {double? startTime, double? duration}) {
    final counter = (_typeCounters[type] ?? 0) + 1;
    _typeCounters[type] = counter;

    final rawStart = startTime ?? _playhead;
    final layer = Layer(
      id: _generateId('layer'),
      name: '${type.label} $counter',
      type: type,
      startTime: rawStart < 0 ? 0.0 : rawStart,
      duration: duration ?? _defaultDurationFor(type),
    );
    addLayer(layer);
    return layer;
  }

  /// Removes [id]. Children keep their keyframes but are detached from the
  /// parent so no dangling references remain in the project graph.
  bool removeLayer(String id) {
    final index = indexOfLayer(id);
    if (index < 0) return false;

    _layers.removeAt(index);
    _keyframes.remove(id); // cascade: keyframes die with the layer

    for (var i = 0; i < _layers.length; i++) {
      if (_layers[i].parentId == id) {
        _layers[i] = _layers[i].withParent(null);
      }
    }

    if (_selectedLayerId == id) _selectedLayerId = null;
    notifyListeners();
    return true;
  }

  // ---------------------------------------------------------------------------
  // Layer editing
  // ---------------------------------------------------------------------------

  /// Generic in-place edit; returns true when the layer actually changed.
  bool updateLayer(String id, Layer Function(Layer layer) mutate) {
    final index = indexOfLayer(id);
    if (index < 0) return false;
    final updated = mutate(_layers[index]);
    if (updated == _layers[index]) return false;
    _layers[index] = updated;
    notifyListeners();
    return true;
  }

  bool renameLayer(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    return updateLayer(id, (layer) => layer.copyWith(name: trimmed));
  }

  /// Updates the layer transform (position / scale / rotation).
  ///
  /// Auto-key: when a property already has keyframes on this layer the new
  /// value is written as a keyframe at the playhead, otherwise the static
  /// transform is replaced.
  bool updateLayerTransform(String layerId, LayerTransform transform) {
    final layer = layerById(layerId);
    if (layer == null || layer.isLocked) return false;

    var dirty = false;
    var base = layer.transform;

    if (!_hasKeyframesOn(layerId, KeyframeProperty.position)) {
      base = base.copyWith(position: transform.position);
    } else {
      dirty |= _upsertKeyframe(
          layerId, KeyframeProperty.position, _playhead, transform.position);
    }

    if (!_hasKeyframesOn(layerId, KeyframeProperty.scale)) {
      base = base.copyWith(scale: transform.scale.clamped());
    } else {
      dirty |= _upsertKeyframe(
          layerId, KeyframeProperty.scale, _playhead, transform.scale.clamped());
    }

    if (!_hasKeyframesOn(layerId, KeyframeProperty.rotation)) {
      base = base.copyWith(rotation: transform.rotation.normalized());
    } else {
      dirty |= _upsertKeyframe(layerId, KeyframeProperty.rotation, _playhead,
          transform.rotation.normalized());
    }

    if (base != layer.transform) {
      final index = indexOfLayer(layerId);
      _layers[index] = layer.copyWith(transform: base);
      dirty = true;
    }

    if (dirty) notifyListeners();
    return dirty;
  }

  /// Updates opacity with the same auto-key semantics as transforms.
  bool updateLayerOpacity(String layerId, double opacity) {
    final layer = layerById(layerId);
    if (layer == null || layer.isLocked) return false;
    final clamped = opacity.clamp(0.0, 1.0).toDouble();

    if (_hasKeyframesOn(layerId, KeyframeProperty.opacity)) {
      final changed =
          _upsertKeyframe(layerId, KeyframeProperty.opacity, _playhead, clamped);
      if (changed) notifyListeners();
      return changed;
    }
    return updateLayer(layerId, (layer) => layer.copyWith(opacity: clamped));
  }

  /// Attaches/detaches a Null Object parent.
  ///
  /// Rules: the parent must exist, must be a [LayerType.nullObject] and the
  /// link must not create a cubic cycle (checked by walking the ancestors).
  bool setLayerParent(String childId, String? parentId) {
    final child = layerById(childId);
    if (child == null || child.isLocked) return false;
    if (child.parentId == parentId) return false;

    if (parentId != null) {
      if (parentId == childId) return false;
      final parent = layerById(parentId);
      if (parent == null || !parent.type.canParent) return false;

      // Cycle guard: parent must not be a descendant of child.
      var cursor = parent;
      var guard = 0;
      while (cursor != null && guard++ < 256) {
        if (cursor.id == childId) return false;
        cursor = layerById(cursor.parentId);
      }
    }

    return updateLayer(childId, (layer) => layer.withParent(parentId));
  }

  bool setLayerLocked(String id, bool locked) =>
      updateLayer(id, (layer) => layer.copyWith(isLocked: locked));

  /// Visibility toggle stays available even when the layer is locked.
  bool setLayerVisible(String id, bool visible) =>
      updateLayer(id, (layer) => layer.copyWith(isVisible: visible));

  /// Moves a layer on the timeline.
  ///
  /// Provide an absolute [startTime] or a relative [delta] (seconds).
  /// Returns false when the layer is locked/missing or nothing changed.
  bool shiftLayerTiming(String id, {double? startTime, double delta = 0.0}) {
    final layer = layerById(id);
    if (layer == null || layer.isLocked) return false;

    final target = startTime ?? (layer.startTime + delta);
    final clamped = target < 0 ? 0.0 : target;
    if ((clamped - layer.startTime).abs() < 1e-9) return false;
    return updateLayer(id, (layer) => layer.copyWith(startTime: clamped));
  }

  // ---------------------------------------------------------------------------
  // Selection (shared by PreviewCanvas + TimelineView)
  // ---------------------------------------------------------------------------

  void selectLayer(String? id) {
    final next = id != null && layerById(id) != null ? id : null;
    if (next == _selectedLayerId) return;
    _selectedLayerId = next;
    notifyListeners();
  }

  void clearSelection() => selectLayer(null);

  // ---------------------------------------------------------------------------
  // Playhead
  // ---------------------------------------------------------------------------

  void seek(double seconds) {
    final upper = projectDuration < 1.0 ? 1.0 : projectDuration;
    final clamped = seconds.clamp(0.0, upper).toDouble();
    if ((clamped - _playhead).abs() < 1e-9) return;
    _playhead = clamped;
    notifyListeners();
  }

  void seekToFrame(int frame) => seek(frame / frameRate);

  void stepFrames(int frames) => seek(_playhead + frames / frameRate);

  // ---------------------------------------------------------------------------
  // Keyframes
  // ---------------------------------------------------------------------------

  /// Sorted snapshot of one keyframe track (never null).
  List<Keyframe> keyframesFor(String layerId, String propertyName) {
    final track = _keyframes[layerId]?[propertyName];
    return track == null ? const <Keyframe>[] : List<Keyframe>.unmodifiable(track);
  }

  /// ENGINE HOT PATH - zero-copy view of a keyframe track (Module 2).
  ///
  /// Returns the *live* sorted list owned by the controller (or a shared empty
  /// list). Never mutate the result, and never keep it after the next edit -
  /// copy through [keyframesFor] when a stable snapshot is required. Sampling
  /// at 60 FPS uses this to avoid the per-call copy of [keyframesFor].
  List<Keyframe> keyframeTrackRef(String layerId, String propertyName) =>
      _keyframes[layerId]?[propertyName] ?? const <Keyframe>[];

  /// Ascending, de-duplicated keyframe times across all properties of a layer
  /// (used to draw keyframe diamonds on timeline clips).
  List<double> keyframeTimes(String layerId) {
    final byProperty = _keyframes[layerId];
    if (byProperty == null || byProperty.isEmpty) return const <double>[];

    final times = <double>[];
    for (final track in byProperty.values) {
      for (final keyframe in track) {
        final duplicate = times.any(
            (t) => (t - keyframe.time).abs() <= Keyframe.timeEpsilon);
        if (!duplicate) times.add(keyframe.time);
      }
    }
    times.sort();
    return times;
  }

  bool hasKeyframes(String layerId) {
    final byProperty = _keyframes[layerId];
    return byProperty != null &&
        byProperty.values.any((track) => track.isNotEmpty);
  }

  bool hasKeyframesAtPlayhead(String layerId) =>
      _hasKeyframesAt(layerId, _playhead);

  /// Inserts [keyframe] (or replaces the existing one at the same time).
  bool addKeyframe(String layerId, Keyframe keyframe) {
    final layer = layerById(layerId);
    if (layer == null || layer.isLocked) return false;
    if (keyframe.propertyName.isEmpty) return false;

    final changed = _upsertKeyframe(
      layerId,
      keyframe.propertyName,
      keyframe.time,
      keyframe.value,
      easingCurve: keyframe.easingCurve,
    );
    if (changed) notifyListeners();
    return changed;
  }

  /// Deletes one keyframe by id (searches every property track).
  bool removeKeyframe(String layerId, String keyframeId) {
    final byProperty = _keyframes[layerId];
    if (byProperty == null) return false;

    var removed = false;
    byProperty.removeWhere((property, track) {
      final before = track.length;
      track.removeWhere((keyframe) => keyframe.id == keyframeId);
      removed |= track.length != before;
      return false;
    });
    byProperty.removeWhere((property, track) => track.isEmpty);
    if (_keyframes[layerId]?.isEmpty ?? false) _keyframes.remove(layerId);
    if (removed) notifyListeners();
    return removed;
  }

  /// Deletes every keyframe sitting (practically) on [time].
  int removeKeyframesAt(String layerId, double time,
      {double epsilon = Keyframe.timeEpsilon}) {
    final byProperty = _keyframes[layerId];
    if (byProperty == null) return 0;

    var removed = 0;
    for (final track in byProperty.values) {
      final before = track.length;
      track.removeWhere((keyframe) => (keyframe.time - time).abs() <= epsilon);
      removed += before - track.length;
    }
    byProperty.removeWhere((property, track) => track.isEmpty);
    if (_keyframes[layerId]?.isEmpty ?? false) _keyframes.remove(layerId);
    if (removed > 0) notifyListeners();
    return removed;
  }

  /// Keys position/scale/rotation (+opacity) at the playhead using the values
  /// currently visible on screen. Returns false when rejected.
  bool addKeyframesAtPlayhead(String layerId) {
    final layer = layerById(layerId);
    if (layer == null || layer.isLocked) return false;

    final transform = resolveLocalTransform(layer);
    var dirty = false;
    dirty |= _upsertKeyframe(
        layerId, KeyframeProperty.position, _playhead, transform.position);
    dirty |= _upsertKeyframe(
        layerId, KeyframeProperty.scale, _playhead, transform.scale);
    dirty |= _upsertKeyframe(
        layerId, KeyframeProperty.rotation, _playhead, transform.rotation);
    dirty |= _upsertKeyframe(
        layerId, KeyframeProperty.opacity, _playhead, resolveOpacity(layer));

    if (dirty) notifyListeners();
    return dirty;
  }

  bool removeKeyframesAtPlayhead(String layerId) =>
      removeKeyframesAt(layerId, _playhead) > 0;

  // ---------------------------------------------------------------------------
  // Evaluation (keyframe -> value at time, with easing)
  // ---------------------------------------------------------------------------

  /// Evaluates a keyframe track at [time]. Returns null when the property is
  /// not animated (callers then fall back to the static value).
  dynamic evaluateProperty(String layerId, String propertyName, double time) {
    final track = _keyframes[layerId]?[propertyName];
    if (track == null || track.isEmpty) return null;
    if (track.length == 1 || time <= track.first.time) return track.first.value;
    if (time >= track.last.time) return track.last.value;

    for (var i = 0; i < track.length - 1; i++) {
      final a = track[i];
      final b = track[i + 1];
      if (time >= a.time && time <= b.time) {
        if (a.easing == KeyframeEasing.hold) return a.value; // stepped segment
        final span = b.time - a.time;
        if (span <= 0) return b.value;
        final raw = ((time - a.time) / span).clamp(0.0, 1.0).toDouble();
        final eased = _curveFor(a).transform(raw);
        return Keyframe.lerpValue(a.value, b.value, eased);
      }
    }
    return track.last.value;
  }

  /// Layer transform with keyframes applied, before parenting.
  LayerTransform resolveLocalTransform(Layer layer, {double? atTime}) {
    final time = atTime ?? _playhead;
    var transform = layer.transform;

    final position = evaluateProperty(layer.id, KeyframeProperty.position, time);
    if (position is Position) transform = transform.copyWith(position: position);

    final scale = evaluateProperty(layer.id, KeyframeProperty.scale, time);
    if (scale is Scale) transform = transform.copyWith(scale: scale.clamped());

    final rotation = evaluateProperty(layer.id, KeyframeProperty.rotation, time);
    if (rotation is Rotation) transform = transform.copyWith(rotation: rotation);

    return transform;
  }

  /// Fully composed transform: local + every Null Object ancestor, outermost
  /// parent first. Guards against corrupted parent chains (max depth 64).
  LayerTransform resolveWorldTransform(Layer layer, {double? atTime}) {
    final time = atTime ?? _playhead;
    var result = resolveLocalTransform(layer, atTime: time);

    var parent = layerById(layer.parentId);
    var guard = 0;
    while (parent != null && guard++ < 64) {
      final parentTransform = resolveLocalTransform(parent, atTime: time);
      result = LayerTransform.compose(parentTransform, result);
      parent = layerById(parent.parentId);
    }
    return result;
  }

  /// Opacity with keyframes applied (clamped 0..1).
  double resolveOpacity(Layer layer, {double? atTime}) {
    final value =
        evaluateProperty(layer.id, KeyframeProperty.opacity, atTime ?? _playhead);
    if (value is num) return value.toDouble().clamp(0.0, 1.0).toDouble();
    return layer.opacity;
  }

  // ---------------------------------------------------------------------------
  // Formatting
  // ---------------------------------------------------------------------------

  /// `HH:MM:SS:FF`
  String formatTimecode(double seconds) {
    final safe = seconds < 0 ? 0.0 : seconds;
    final totalFrames = (safe * frameRate).round();
    final frames = totalFrames % frameRate;
    final totalSeconds = totalFrames ~/ frameRate;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds ~/ 60) % 60;
    final secs = totalSeconds % 60;
    return '${_pad(hours)}:${_pad(minutes)}:${_pad(secs)}:${_pad(frames)}';
  }

  /// Compact ruler label: `12` / `12.5` under a minute, `1:30` above.
  String formatRulerLabel(double seconds) {
    final safe = seconds < 0 ? 0.0 : seconds;
    if (safe < 60) {
      if ((safe - safe.roundToDouble()).abs() < 0.001) {
        return safe.round().toString();
      }
      return safe.toStringAsFixed(safe < 10 ? 1 : 0);
    }
    final minutes = safe ~/ 60;
    final secs = (safe - minutes * 60).round();
    return '$minutes:${_pad(secs)}';
  }

  @override
  void dispose() {
    _layers.clear();
    _keyframes.clear();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  String _generateId(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_idSeed++}';

  static String _pad(int value) => value.toString().padLeft(2, '0');

  static double _defaultDurationFor(LayerType type) => switch (type) {
        LayerType.video => 5.0,
        LayerType.audio => 5.0,
        LayerType.text => 3.0,
        LayerType.shape => 3.0,
        LayerType.nullObject => 5.0,
        LayerType.adjustmentLayer => 5.0,
      };

  bool _hasKeyframesOn(String layerId, String propertyName) {
    final track = _keyframes[layerId]?[propertyName];
    return track != null && track.isNotEmpty;
  }

  bool _hasKeyframesAt(String layerId, double time,
      {double epsilon = Keyframe.timeEpsilon}) {
    final byProperty = _keyframes[layerId];
    if (byProperty == null) return false;
    for (final track in byProperty.values) {
      for (final keyframe in track) {
        if ((keyframe.time - time).abs() <= epsilon) return true;
      }
    }
    return false;
  }

  /// Inserts or replaces a keyframe value at [time]. Returns true on change.
  bool _upsertKeyframe(
    String layerId,
    String propertyName,
    double time,
    dynamic value, {
    String? easingCurve,
  }) {
    final byProperty =
        _keyframes.putIfAbsent(layerId, () => <String, List<Keyframe>>{});
    final track = byProperty.putIfAbsent(propertyName, () => <Keyframe>[]);

    for (var i = 0; i < track.length; i++) {
      final existing = track[i];
      if (existing.isAtTime(time)) {
        if (existing.value == value) return false;
        track[i] = existing.copyWith(
          time: time,
          value: value,
          easingCurve: easingCurve ?? existing.easingCurve,
        );
        return true;
      }
    }

    // The raw easing string is stored verbatim so custom cubic-Bezier ids
    // ("cubic(x1,y1,x2,y2)") survive a persistence round trip. Preset ids are
    // unchanged, and evaluators fall back to linear for unknown values.
    track.add(Keyframe(
      id: _generateId('kf'),
      propertyName: propertyName,
      time: time,
      value: value,
      easingCurve: easingCurve ?? KeyframeEasing.linear.id,
    ));
    track.sort(Keyframe.compare);
    return true;
  }

  static Curve _curveFor(Keyframe keyframe) => switch (keyframe.easing) {
        KeyframeEasing.linear => Curves.linear,
        KeyframeEasing.easeIn => Curves.easeIn,
        KeyframeEasing.easeOut => Curves.easeOut,
        KeyframeEasing.easeInOut => Curves.easeInOut,
        // `hold` is handled as a stepped segment in evaluateProperty.
        KeyframeEasing.hold => Curves.linear,
      };
}
