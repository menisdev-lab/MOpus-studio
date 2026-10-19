// =============================================================================
// MOpus Studio - lib/engine/ffmpeg_renderer.dart
// -----------------------------------------------------------------------------
// FFmpeg command + filter-graph backend (Module 3).
//
// The renderer turns an [ExportPlan] (planner output) into either
//   * an inspectable argument list / shell script - diffable, CI-friendly, or
//   * a live FFmpeg process with parsed `-progress pipe:1` output.
//
// Graph strategy ("time-sliced baking"), chosen for syntax certainty and low
// memory on 2GB devices:
//   * Animated POSITION and ROTATION are emitted as `overlay` / `rotate`
//     expressions. Both filters evaluate their expressions per frame, so they
//     stay exact, continuous and cheap.
//   * Animated OPACITY and SCALE are baked by slicing the layer stream with
//     `trim` + `concat`: every slice carries a constant `colorchannelmixer=aa`
//     and `scale` value (no per-frame alpha expressions, which not every
//     FFmpeg build supports). Linear 0<->1 opacity ramps collapse into a single
//     `fade` slice, so real fades stay perfectly smooth.
//   * Adjustment layers follow Module 2 semantics: an adjustment affects every
//     visual layer below it; the aggregated parameters become an
//     [EffectsLibrary] chain appended to those layers.
//
// Coordinates: the editor stores positions relative to the canvas centre, so
// overlay expressions are `(main_w-overlay_w)/2 + x(t)` - byte-identical to
// what `preview_canvas.dart` paints.
//
// Process execution goes through `dart:io` [Process]. That works on desktop,
// CI and Android as long as an FFmpeg host (binary or bundled `.so` wrapper)
// is present; the packaged Android backend plugs into the same [RenderBackend]
// interface, and until it ships the script output path covers CI + desktop.
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/keyframe_model.dart';
import '../models/layer_model.dart';
import 'animation_interpolator.dart';
import 'effects_library.dart';
import 'export_engine.dart';

// -----------------------------------------------------------------------------
// Sampled-curve expressions
// -----------------------------------------------------------------------------

/// One time/value knot of a sampled animation curve.
@immutable
class FfmpegKnot {
  const FfmpegKnot(this.time, this.value);

  final double time;
  final double value;

  @override
  String toString() => 'FfmpegKnot(${time.toStringAsFixed(3)}, $value)';
}

/// Builds FFmpeg arithmetic expressions from sampled curves.
///
/// Everything is emitted as nested `if(lt(t,t1), v0, if(lt(t,t2), ...))`, the
/// value being linearly interpolated between knots and clamped outside the
/// knot range - the same shape Module 2's interpolator produces. No FFmpeg
/// build flags are required beyond the expression evaluator every release has.
abstract final class FfmpegExpressionBuilder {
  /// Maximum number of knots inside one expression. Longer curves are
  /// decimated so the expression parser never recurses too deep.
  static const int maxKnots = 48;

  /// Constant expression (no `t` dependency).
  static String constant(double value) => ffmpegNumber(value);

  /// Builds a piecewise-linear `expr(t)` from time-sorted [knots].
  ///
  /// [variable] is the target filter's time variable (`t` everywhere we use
  /// it). The expression clamps to the first knot before it and to the last
  /// knot after it, mirroring [AnimationInterpolator.sample].
  static String piecewise(
    List<FfmpegKnot> knots, {
    String variable = 't',
  }) {
    if (knots.isEmpty) return '0';
    final points = _decimate(knots);
    if (points.length == 1) return constant(points.first.value);

    final buffer = StringBuffer();
    for (var i = points.length - 1; i >= 1; i--) {
      final a = points[i - 1];
      final b = points[i];
      buffer.write('if(lt($variable,${ffmpegNumber(b.time)}),');
      final span = b.time - a.time;
      if (span <= 0.0) {
        buffer.write(constant(b.value));
      } else {
        final slope = (b.value - a.value) / span;
        // The first segment also clamps *before* knot 0 via max(...,0).
        final offset = i == 1
            ? 'max($variable-${ffmpegNumber(a.time)},0)'
            : '($variable-${ffmpegNumber(a.time)})';
        buffer.write(
            '${ffmpegNumber(a.value)}+$offset*${ffmpegNumber(slope)}');
      }
      buffer.write(',');
    }
    buffer.write(constant(points.last.value));
    for (var i = 1; i < points.length; i++) {
      buffer.write(')');
    }
    return buffer.toString();
  }

  /// Samples [track] into knots, subdividing every segment so eased curves are
  /// followed closely by the linear expression approximation.
  ///
  /// [extract] pulls one scalar out of a sampled keyframe value (x, y, degrees,
  /// opacity...). Empty tracks produce an empty knot list and the caller falls
  /// back to the layer's static value.
  static List<FfmpegKnot> knotsFromTrack(
    List<Keyframe> track, {
    required double Function(Object? value) extract,
    int subdivisionsPerSegment = 4,
  }) {
    if (track.isEmpty) return const <FfmpegKnot>[];
    final knots = <FfmpegKnot>[
      FfmpegKnot(track.first.time, extract(track.first.value)),
    ];
    if (track.length == 1) return knots;
    for (var i = 0; i < track.length - 1; i++) {
      final a = track[i];
      final b = track[i + 1];
      final span = b.time - a.time;
      final steps = span > 0.0 && subdivisionsPerSegment > 1
          ? subdivisionsPerSegment
          : 1;
      for (var step = 1; step <= steps; step++) {
        final time = a.time + span * (step / steps);
        final sampled = AnimationInterpolator.sample(track, time);
        knots.add(FfmpegKnot(time, extract(sampled)));
      }
    }
    return knots;
  }

  /// Keeps at most [maxKnots] points, preserving the first and last knot so
  /// the clamped ends never move.
  static List<FfmpegKnot> _decimate(List<FfmpegKnot> knots) {
    if (knots.length <= maxKnots) return knots;
    final result = <FfmpegKnot>[];
    final step = (knots.length - 1) / (maxKnots - 1);
    for (var i = 0; i < maxKnots; i++) {
      final index = i == maxKnots - 1 ? knots.length - 1 : (i * step).floor();
      final knot = knots[index];
      if (result.isEmpty || result.last.time != knot.time) {
        result.add(knot);
      }
    }
    return result;
  }
}

// -----------------------------------------------------------------------------
// Render job
// -----------------------------------------------------------------------------

/// A ready-to-run FFmpeg invocation.
@immutable
class FfmpegRenderJob {
  const FfmpegRenderJob({
    required this.arguments,
    required this.outputPath,
    required this.durationSeconds,
    required this.totalFrames,
    this.filterGraph,
  });

  /// Complete argument vector without the leading binary name.
  final List<String> arguments;

  final String outputPath;
  final double durationSeconds;
  final int totalFrames;

  /// The `-filter_complex` payload, kept separately for inspection/debugging.
  final String? filterGraph;

  /// One-line command for logs and bug reports (POSIX quoting).
  String get commandLine =>
      <String>['ffmpeg', ...arguments].map(shellQuote).join(' ');

  /// Multi-line POSIX shell script: runs unchanged on desktop Linux/macOS,
  /// CI, WSL and Git Bash on Windows.
  String toShellScript({String comment = 'MOpus Studio offline render'}) {
    final buffer = StringBuffer('#!/usr/bin/env sh\n');
    buffer.writeln('# $comment');
    buffer.writeln('# generated - safe to inspect, tweak and re-run');
    buffer.write(<String>['ffmpeg', ...arguments]
        .map(shellQuote)
        .join(' \\\n  '));
    buffer.writeln();
    return buffer.toString();
  }

  @override
  String toString() => 'FfmpegRenderJob($outputPath, ${arguments.length} args)';
}

/// POSIX shell quoting: leaves safe tokens untouched, wraps everything else in
/// single quotes and escapes embedded quotes.
String shellQuote(String value) {
  if (value.isEmpty) return "''";
  final safe = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(value);
  if (safe) return value;
  return "'${value.replaceAll("'", "'\"'\"'")}'";
}

// -----------------------------------------------------------------------------
// Internal graph model
// -----------------------------------------------------------------------------

/// One constant-parameter time slice of a layer stream.
///
/// [alpha] and the scale pair are applied as plain filter values, which is how
/// the renderer avoids per-frame alpha expressions entirely.
@immutable
class _LayerSlice {
  const _LayerSlice({
    required this.start,
    required this.end,
    required this.alpha,
    required this.scaleX,
    required this.scaleY,
    this.fade,
  });

  /// Layer-relative seconds, `[start, end)`.
  final double start;
  final double end;

  /// Constant alpha for this slice (ignored when [fade] is set).
  final double alpha;

  final double scaleX;
  final double scaleY;

  /// `'in'` on a 0 -> 1 linear ramp, `'out'` on 1 -> 0; `null` for constants.
  final String? fade;

  double get duration => end - start;

  @override
  String toString() => '_LayerSlice($start..$end, a=$alpha, '
      's=$scaleX/$scaleY${fade == null ? '' : ', fade $fade'})';
}

/// Adjustment layer positioned in the stack (0 = bottom).
@immutable
class _AdjustmentEntry {
  const _AdjustmentEntry(this.stackIndex, this.effect);

  final int stackIndex;
  final AdjustmentEffect effect;
}

/// Assembles the argument vector and the `-filter_complex` graph for a plan.
class _GraphAssembler {
  _GraphAssembler(this.plan)
      : source = plan.source,
        settings = plan.settings;

  final ExportPlan plan;
  final RenderProjectSource source;
  final ExportSettings settings;

  final List<String> _inputs = <String>[];
  final List<String> _filters = <String>[];
  int _inputCursor = 0;
  int _labelCursor = 0;

  static const double _degToRad = 0.017453292519943295;
  static const double _alphaEpsilon = 0.002;

  int get _width => settings.resolution.width;
  int get _height => settings.resolution.height;
  int get _fps => settings.frameRate;
  double get _duration => plan.durationSeconds;

  String _label(String prefix) => '$prefix${_labelCursor++}';

  int _addInput(List<String> args) {
    _inputs.addAll(args);
    return _inputCursor++;
  }

  static double _number(Object? value, [double fallback = 0.0]) =>
      value is num ? value.toDouble() : fallback;

  double _clampTime(double time, double instead) =>
      time.isFinite ? time.clamp(0.0, instead).toDouble() : 0.0;

  static int _ms(double seconds) => (seconds * 1000).round();

  // ---------------------------------------------------------------------------
  // Assembly
  // ---------------------------------------------------------------------------

  FfmpegRenderJob assemble(String outputPath) {
    // Input 0: the canvas. Jet Black by default, rendered at the export size.
    final canvas = _addInput(<String>[
      '-f', 'lavfi',
      '-i',
      'color=c=${settings.backgroundColorHex}'
          ':s=${_width}x$_height:r=$_fps:d=${ffmpegNumber(_duration)}',
    ]);
    final baseLabel = _label('canvas');
    _filters.add('[$canvas:v]format=rgba,setsar=1[$baseLabel]');

    final adjustments = _collectAdjustments();
    var cursor = baseLabel;

    // Bottom -> top: later overlays paint on top, matching stack index order.
    for (final id in plan.visualLayerIds) {
      final layer = source.layerById(id);
      if (layer == null || !layer.isVisible || layer.duration <= 0.0) continue;
      switch (layer.type) {
        case LayerType.adjustmentLayer:
        case LayerType.nullObject:
        case LayerType.audio:
          continue; // no stream of their own
        case LayerType.video:
          final path = source.assetPathFor(layer);
          if (path.isEmpty) continue;
          cursor = _appendVideoLayer(cursor, layer, path, adjustments);
        case LayerType.text:
          cursor = _appendProceduralLayer(cursor, layer, adjustments, text: true);
        case LayerType.shape:
          cursor =
              _appendProceduralLayer(cursor, layer, adjustments, text: false);
      }
    }

    final videoOut = _label('vout');
    _filters.add('[$cursor]format=yuv420p,fps=$_fps,setsar=1[$videoOut]');

    final audioOut = _appendAudioMix();

    final args = <String>[
      '-hide_banner',
      '-nostdin',
      '-y',
      '-filter_complex_threads', '${settings.filterThreads}',
      ..._inputs,
      '-filter_complex', _filters.join(';'),
      '-map', '[$videoOut]',
      if (audioOut != null) ...<String>['-map', '[$audioOut]'],
      '-c:v', 'libx264',
      '-preset', settings.encoderPreset,
      if (settings.crf != null)
        ...<String>['-crf', '${settings.crf}']
      else ...<String>[
        '-b:v', '${settings.videoBitrateKbps}k',
        '-maxrate', '${(settings.videoBitrateKbps * 1.5).round()}k',
        '-bufsize', '${settings.videoBitrateKbps * 2}k',
      ],
      '-pix_fmt', 'yuv420p',
      '-r', '$_fps',
      '-g', '${_fps * 2}',
      '-threads', '${settings.threads}',
      if (audioOut != null)
        ...<String>[
          '-c:a', 'aac',
          '-b:a', '${settings.audioBitrateKbps}k',
          '-ar', '${settings.audioSampleRate}',
          '-ac', '2',
        ]
      else
        '-an',
      '-t', ffmpegNumber(_duration),
      if (settings.fastStart) ...<String>['-movflags', '+faststart'],
      '-progress', 'pipe:1',
      '-nostats',
      outputPath,
    ];

    return FfmpegRenderJob(
      arguments: args,
      outputPath: outputPath,
      durationSeconds: _duration,
      totalFrames: plan.frameCount,
      filterGraph: _filters.join(';'),
    );
  }

  /// Adjustment layers with a non-neutral effect, sorted by stack position.
  List<_AdjustmentEntry> _collectAdjustments() {
    final entries = <_AdjustmentEntry>[];
    for (final id in plan.visualLayerIds) {
      final layer = source.layerById(id);
      if (layer == null || layer.type != LayerType.adjustmentLayer) continue;
      final effect = source.adjustmentEffectOf(id);
      if (effect.isNeutral) continue;
      final index = source.indexOfLayer(id);
      if (index < 0) continue;
      entries.add(_AdjustmentEntry(index, effect));
    }
    entries.sort((a, b) => a.stackIndex.compareTo(b.stackIndex));
    return entries;
  }

  /// Module 2 semantics: every adjustment layer *above* [layer] contributes,
  /// bottom-most first (`combine` applies the inner effect first).
  AdjustmentEffect _aggregateFor(
      Layer layer, List<_AdjustmentEntry> adjustments) {
    if (adjustments.isEmpty) return AdjustmentEffect.neutral;
    final index = source.indexOfLayer(layer.id);
    if (index < 0) return AdjustmentEffect.neutral;
    var accumulated = AdjustmentEffect.neutral;
    for (final entry in adjustments) {
      if (entry.stackIndex > index) {
        accumulated = entry.effect.combine(accumulated);
      }
    }
    return accumulated;
  }

  /// Visual filter chain contributed by the adjustment pass-through.
  String _effectChainFor(AdjustmentEffect aggregate) {
    if (aggregate.isNeutral) return '';
    return EffectsLibrary.chain(EffectsLibrary.fromEffect(aggregate));
  }

  // ---------------------------------------------------------------------------
  // Slice planning (opacity / scale baking)
  // ---------------------------------------------------------------------------

  /// Splits `[0, clipDuration]` into constant-parameter slices.
  ///
  /// Boundaries come from the opacity and scale tracks; segments that change
  /// are subdivided [ExportSettings.bakeSubdivisions] times. A linear 0 <-> 1
  /// opacity ramp becomes exactly one slice with a continuous `fade` instead,
  /// so ordinary fade-in/out stays perfectly smooth.
  List<_LayerSlice> _planSlices(
    Layer layer,
    double clipDuration, {
    double extraAlpha = 1.0,
  }) {
    final boundaries = <double>[0.0, clipDuration];
    final fades = <int, String>{};

    final opacityTrack =
        source.keyframesFor(layer.id, KeyframeProperty.opacity);
    for (var i = 0; i < opacityTrack.length - 1; i++) {
      final a = opacityTrack[i];
      final b = opacityTrack[i + 1];
      final span = b.time - a.time;
      final start = _clampTime(a.time, clipDuration);
      final end = _clampTime(b.time, clipDuration);
      boundaries.add(start);
      boundaries.add(end);

      final va = _number(a.value);
      final vb = _number(b.value);
      final fadeIn = va <= _alphaEpsilon && vb >= 1.0 - _alphaEpsilon;
      final fadeOut = va >= 1.0 - _alphaEpsilon && vb <= _alphaEpsilon;
      if (a.easing == KeyframeEasing.linear &&
          span > 0.0 &&
          (fadeIn || fadeOut)) {
        if (_ms(end) > _ms(start)) {
          fades[_ms(start)] = fadeIn ? 'in' : 'out';
        }
        continue;
      }

      final steps = settings.bakeSubdivisions;
      for (var step = 1; step < steps; step++) {
        boundaries
            .add(_clampTime(a.time + span * (step / steps), clipDuration));
      }
    }

    final scaleTrack = source.keyframesFor(layer.id, KeyframeProperty.scale);
    for (var i = 0; i < scaleTrack.length - 1; i++) {
      final a = scaleTrack[i];
      final b = scaleTrack[i + 1];
      final span = b.time - a.time;
      final steps = settings.bakeSubdivisions;
      for (var step = 1; step < steps; step++) {
        boundaries
            .add(_clampTime(a.time + span * (step / steps), clipDuration));
      }
      boundaries.add(_clampTime(a.time, clipDuration));
      boundaries.add(_clampTime(b.time, clipDuration));
    }

    final sorted = boundaries.toSet().toList()..sort();

    final slices = <_LayerSlice>[];
    for (var i = 0; i < sorted.length - 1; i++) {
      final start = sorted[i];
      final end = sorted[i + 1];
      if (end - start <= 0.0005) continue;
      final mid = layer.startTime + (start + end) / 2;
      final transform = source.worldTransformAt(layer, mid);
      final alpha = (source.opacityAt(layer, mid) * extraAlpha)
          .clamp(0.0, 1.0)
          .toDouble();
      final fade = fades[_ms(start)];
      slices.add(_LayerSlice(
        start: start,
        end: end,
        alpha: alpha,
        scaleX: transform.scale.x,
        scaleY: transform.scale.y,
        fade: fade != null && end - start > 0.05 ? fade : null,
      ));
    }

    if (slices.isEmpty) {
      final transform = source.worldTransformAt(layer, layer.startTime);
      slices.add(_LayerSlice(
        start: 0.0,
        end: clipDuration,
        alpha: (source.opacityAt(layer, layer.startTime) * extraAlpha)
            .clamp(0.0, 1.0)
            .toDouble(),
        scaleX: transform.scale.x,
        scaleY: transform.scale.y,
      ));
    }
    return slices;
  }

  // ---------------------------------------------------------------------------
  // Layer streams
  // ---------------------------------------------------------------------------

  /// Builds the stream for one visual layer and returns its output label.
  ///
  /// Fast path (no fade, one slice): the whole chain stays linear and the
  /// overlay receives a content-sized stream - the cheapest option on 2GB
  /// devices. Sliced path: `split` + `trim` + `concat`, padded to the canvas
  /// so every concat input has identical geometry.
  String _buildLayerStream({
    required String inputLabel,
    required Layer layer,
    required AdjustmentEffect aggregate,
    required List<_LayerSlice> slices,
    required bool fitToCanvas,
    String? proceduralFilter,
  }) {
    final parts = <String>[];
    if (fitToCanvas) {
      parts.add('scale=w=$_width:h=$_height'
          ':force_original_aspect_ratio=decrease:force_divisible_by=2');
    }
    parts.add('setsar=1');
    parts.add('format=rgba');
    if (proceduralFilter != null) parts.add(proceduralFilter);
    final effects = _effectChainFor(aggregate);
    if (effects.isNotEmpty) parts.add(effects);
    final rotation = _rotationFilter(layer);
    if (rotation.isNotEmpty) parts.add(rotation);

    final label = _label('layer');
    if (slices.length == 1 && slices.first.fade == null) {
      final slice = slices.first;
      final buffer = StringBuffer('[$inputLabel]${parts.join(',')}');
      final scale = _scaleFilter(slice);
      if (scale != null) buffer.write(',$scale');
      if (slice.alpha < 1.0 - _alphaEpsilon) {
        buffer.write(',colorchannelmixer=aa=${ffmpegNumber(slice.alpha)}');
      }
      buffer.write(',setpts=PTS+${ffmpegNumber(layer.startTime)}/TB');
      buffer.write('[$label]');
      _filters.add(buffer.toString());
      return label;
    }

    final splitLabels = <String>[];
    for (var i = 0; i < slices.length; i++) {
      splitLabels.add(_label('slice'));
    }
    _filters.add('[$inputLabel]${parts.join(',')}'
        ',split=${slices.length}${splitLabels.map((l) => '[$l]').join()}');

    final outLabels = <String>[];
    for (var i = 0; i < slices.length; i++) {
      final slice = slices[i];
      final out = _label('cut');
      final buffer = StringBuffer('[$splitLabels[i]]');
      buffer.write('trim=start=${ffmpegNumber(slice.start)}'
          ':end=${ffmpegNumber(slice.end)}');
      buffer.write(',setpts=PTS-STARTPTS');
      final scale = _scaleFilter(slice);
      if (scale != null) buffer.write(',$scale');
      // Pad to the canvas: concat requires identical dimensions per input.
      buffer.write(',pad=w=$_width:h=$_height'
          ':x=(ow-iw)/2:y=(oh-ih)/2:color=black@0');
      if (slice.fade != null) {
        buffer.write(',fade=t=${slice.fade}:st=0'
            ':d=${ffmpegNumber(slice.duration)}:alpha=1');
      } else if (slice.alpha < 1.0 - _alphaEpsilon) {
        buffer.write(',colorchannelmixer=aa=${ffmpegNumber(slice.alpha)}');
      }
      buffer.write('[$out]');
      _filters.add(buffer.toString());
      outLabels.add(out);
    }

    _filters.add('${outLabels.map((l) => '[$l]').join()}'
        'concat=n=${slices.length}:v=1:a=0'
        ',setpts=PTS+${ffmpegNumber(layer.startTime)}/TB[$label]');
    return label;
  }

  String? _scaleFilter(_LayerSlice slice) {
    final unit = (slice.scaleX - 1.0).abs() < 0.0005 &&
        (slice.scaleY - 1.0).abs() < 0.0005;
    if (unit) return null;
    return 'scale=w=iw*${ffmpegNumber(slice.scaleX)}'
        ':h=ih*${ffmpegNumber(slice.scaleY)}';
  }

  /// Per-frame rotation expression. `rotate` re-evaluates `a` every frame and
  /// defaults `ow`/`oh` to the rotated bounding box, which keeps the layer's
  /// centre in place - exactly what the preview does.
  String _rotationFilter(Layer layer) {
    final times = _animationSampleTimes(layer);
    final radians = _degToRad;
    final knots = _worldKnots(
      layer,
      times,
      (transform) => transform.rotation.degrees * radians,
    );
    final base = layer.transform.rotation.degrees * radians;
    final expression = _expressionFrom(knots, base);
    if (expression == '0') return '';
    return "rotate=a='$expression':c=none";
  }

  // ---------------------------------------------------------------------------
  // World-transform sampling
  // ---------------------------------------------------------------------------

  /// Times worth sampling for [layer]: its own transform keyframes, every
  /// ancestor's (null objects move their children), the layer's window edges
  /// and interior points of each segment so eased curves stay accurate.
  List<double> _animationSampleTimes(Layer layer) {
    final times = <double>[layer.startTime, layer.endTime];
    var current = layer;
    var guard = 0;
    while (guard++ < 64) {
      for (final property in KeyframeProperty.transform) {
        final track = source.keyframesFor(current.id, property);
        for (var i = 0; i < track.length; i++) {
          times.add(track[i].time);
          if (i + 1 < track.length) {
            final span = track[i + 1].time - track[i].time;
            if (span > 0.0) {
              times.add(track[i].time + span * 0.25);
              times.add(track[i].time + span * 0.5);
              times.add(track[i].time + span * 0.75);
            }
          }
        }
      }
      final parent = source.layerById(current.parentId);
      if (parent == null) break;
      current = parent;
    }
    times.sort();
    return times;
  }

  List<FfmpegKnot> _worldKnots(
    Layer layer,
    List<double> times,
    double Function(LayerTransform transform) extract,
  ) {
    final knots = <FfmpegKnot>[];
    for (final time in times) {
      knots.add(FfmpegKnot(time, extract(source.worldTransformAt(layer, time))));
    }
    return knots;
  }

  /// Constant expression when the curve never changes, piecewise otherwise.
  String _expressionFrom(List<FfmpegKnot> knots, double fallback) {
    if (knots.isEmpty) return FfmpegExpressionBuilder.constant(fallback);
    final first = knots.first.value;
    for (final knot in knots) {
      if (knot.value != first) {
        return FfmpegExpressionBuilder.piecewise(knots);
      }
    }
    return FfmpegExpressionBuilder.constant(first);
  }

  String _positionExpression(Layer layer, int axis) {
    final times = _animationSampleTimes(layer);
    final knots = _worldKnots(
      layer,
      times,
      (transform) =>
          axis == 0 ? transform.position.x : transform.position.y,
    );
    return _expressionFrom(
      knots,
      axis == 0 ? layer.transform.position.x : layer.transform.position.y,
    );
  }

  String _appendOverlay(String cursor, String layerLabel, Layer layer) {
    final out = _label('mix');
    final x = _positionExpression(layer, 0);
    final y = _positionExpression(layer, 1);
    final buffer = StringBuffer('[$cursor][$layerLabel]overlay=');
    buffer.write("x='(main_w-overlay_w)/2+$x'");
    buffer.write(":y='(main_h-overlay_h)/2+$y'");
    buffer.write(":enable='between(t,${ffmpegNumber(layer.startTime)},"
        "${ffmpegNumber(layer.endTime)})'");
    buffer.write(':eof_action=pass');
    buffer.write('[$out]');
    _filters.add(buffer.toString());
    return out;
  }

  // ---------------------------------------------------------------------------
  // Layer sources
  // ---------------------------------------------------------------------------

  String _appendVideoLayer(
    String cursor,
    Layer layer,
    String path,
    List<_AdjustmentEntry> adjustments,
  ) {
    // `-stream_loop -1` keeps still images and short clips alive across the
    // whole layer window; `-ss`/`-t` trim to the timeline.
    final input = _addInput(<String>[
      '-stream_loop', '-1',
      '-ss', ffmpegNumber(layer.startTime),
      '-t', ffmpegNumber(layer.duration),
      '-i', path,
    ]);
    final aggregate = _aggregateFor(layer, adjustments);
    final slices = _planSlices(
      layer,
      layer.duration,
      extraAlpha: aggregate.opacityMultiplier,
    );
    final label = _buildLayerStream(
      inputLabel: '$input:v',
      layer: layer,
      aggregate: aggregate,
      slices: slices,
      fitToCanvas: true,
    );
    return _appendOverlay(cursor, label, layer);
  }

  /// Text and shape layers are generated on a transparent lavfi canvas, so
  /// they flow through the exact same transform/effects pipeline as media.
  String _appendProceduralLayer(
    String cursor,
    Layer layer,
    List<_AdjustmentEntry> adjustments, {
    required bool text,
  }) {
    final clipDuration = layer.duration;
    final input = _addInput(<String>[
      '-f', 'lavfi',
      '-i', 'color=c=black@0:s=${_width}x$_height:r=$_fps'
          ':d=${ffmpegNumber(clipDuration)}',
    ]);
    final aggregate = _aggregateFor(layer, adjustments);
    final shapeAlpha = text ? 1.0 : source.shapeSpecFor(layer).opacity;
    final slices = _planSlices(
      layer,
      clipDuration,
      extraAlpha: aggregate.opacityMultiplier * shapeAlpha,
    );
    final label = _buildLayerStream(
      inputLabel: '$input:v',
      layer: layer,
      aggregate: aggregate,
      slices: slices,
      fitToCanvas: false,
      proceduralFilter: text ? _drawTextFilter(layer) : _drawBoxFilter(layer),
    );
    return _appendOverlay(cursor, label, layer);
  }

  /// Text content comes from the layer name until the text module stores real
  /// content; Pure White, centred, sized in canvas pixels.
  String _drawTextFilter(Layer layer) {
    final fontFile = settings.textFontFile;
    final fontArg = (fontFile != null && fontFile.isNotEmpty)
        ? 'fontfile=${_escapeFilterValue(fontFile)}'
        : "font='Sans'";
    return 'drawtext=$fontArg'
        ':text=${_escapeDrawText(layer.name)}'
        ':fontsize=${settings.textFontSize}'
        ':fontcolor=0xFFFFFF'
        ':x=(w-text_w)/2'
        ':y=(h-text_h)/2'
        ':expansion=none';
  }

  String _drawBoxFilter(Layer layer) {
    final spec = source.shapeSpecFor(layer);
    final width = (spec.widthFraction.clamp(0.0, 1.0) * _width).round();
    final height = (spec.heightFraction.clamp(0.0, 1.0) * _height).round();
    final x = ((_width - width) / 2).round();
    final y = ((_height - height) / 2).round();
    return 'drawbox=x=$x:y=$y:w=$width:h=$height'
        ':color=${spec.colorHex}:t=fill';
  }

  /// Escapes a value inside `key=value` (Windows paths carry colons).
  String _escapeFilterValue(String value) => value
      .replaceAll('\\', r'\\')
      .replaceAll(':', r'\:')
      .replaceAll("'", r"\'");

  /// drawtext text: quoted so spaces/commas survive; `expansion=none` keeps
  /// `%` literal.
  String _escapeDrawText(String value) {
    final escaped = value
        .replaceAll('\\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll(':', r'\:');
    return "'$escaped'";
  }

  // ---------------------------------------------------------------------------
  // Audio
  // ---------------------------------------------------------------------------

  /// Mixes every audible layer with `adelay` + `amix`. Returns the output
  /// label, or `null` when the plan has no audio (video gets `-an`).
  String? _appendAudioMix() {
    final labels = <String>[];
    for (final id in plan.audioLayerIds) {
      final layer = source.layerById(id);
      if (layer == null || !layer.isVisible || layer.duration <= 0.0) continue;
      final path = source.assetPathFor(layer);
      if (path.isEmpty) continue;

      final input = _addInput(<String>[
        '-ss', ffmpegNumber(layer.startTime),
        '-t', ffmpegNumber(layer.duration),
        '-i', path,
      ]);
      // Volume keyframes are resolved at the layer start: the mix bus stays a
      // single constant-gain pass (animated gain arrives with the audio module).
      final volume = _number(
        AnimationInterpolator.sample(
          source.keyframesFor(layer.id, KeyframeProperty.volume),
          layer.startTime,
        ),
        1.0,
      );
      final delayMs = (layer.startTime * 1000).round();
      final label = _label('audio');
      final chain = StringBuffer('[$input:a]');
      chain.write('atrim=0:${ffmpegNumber(layer.duration)}');
      chain.write(',asetpts=PTS-STARTPTS');
      chain.write(',aresample=${settings.audioSampleRate}');
      if (delayMs > 0) chain.write(',adelay=$delayMs|$delayMs');
      if ((volume - 1.0).abs() > 0.001) {
        chain.write(
            ',volume=${ffmpegNumber(volume.clamp(0.0, 4.0).toDouble())}');
      }
      chain.write('[$label]');
      _filters.add(chain.toString());
      labels.add(label);
    }

    if (labels.isEmpty) return null;

    final out = _label('mixed');
    if (labels.length == 1) {
      _filters.add('[${labels.first}]apad=pad_dur=${ffmpegNumber(_duration)}'
          ',atrim=0:${ffmpegNumber(_duration)}[$out]');
      return out;
    }
    final refs = labels.map((label) => '[$label]').join();
    _filters.add('${refs}amix=inputs=${labels.length}'
        ':dropout_transition=0:normalize=0'
        ',atrim=0:${ffmpegNumber(_duration)}[$out]');
    return out;
  }
}

// -----------------------------------------------------------------------------
// Process runner
// -----------------------------------------------------------------------------

/// Runs one [FfmpegRenderJob] and converts `-progress pipe:1` output into
/// [ExportProgress] snapshots.
///
/// `-progress` keeps stdout machine-readable (`frame=`, `fps=`, `out_time_us=`,
/// `speed=`, `progress=`), while stderr stays human-readable for the log sheet.
class FfmpegProcessRunner {
  FfmpegProcessRunner({this.binary = 'ffmpeg'});

  /// Binary name (`ffmpeg`) or absolute path.
  final String binary;

  Process? _process;
  bool _cancelled = false;

  /// `true` while a process is alive.
  bool get isRunning => _process != null;

  Future<RenderOutcome> run(
    FfmpegRenderJob job, {
    void Function(ExportProgress progress)? onProgress,
    void Function(String line)? onLog,
    int maxLogLines = 400,
  }) async {
    final stopwatch = Stopwatch()..start();
    final logLines = <String>[];

    void log(String line) {
      if (logLines.length >= maxLogLines) logLines.removeAt(0);
      logLines.add(line);
      onLog?.call(line);
    }

    Process process;
    try {
      process = await Process.start(binary, job.arguments);
    } catch (error) {
      return RenderOutcome.failure('Could not start "$binary": $error',
          outputPath: job.outputPath);
    }
    _process = process;
    _cancelled = false;

    var frames = 0;
    var fps = 0.0;
    var speed = 0.0;
    var outTimeUs = 0;

    void emit() {
      final seconds = outTimeUs / 1000000.0;
      final fraction = job.durationSeconds <= 0
          ? 0.0
          : (seconds / job.durationSeconds).clamp(0.0, 1.0).toDouble();
      onProgress?.call(ExportProgress(
        fraction: fraction,
        encodedFrames: frames,
        totalFrames: job.totalFrames,
        fps: fps,
        speed: speed,
        elapsed: stopwatch.elapsed,
      ));
    }

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final separator = line.indexOf('=');
      if (separator <= 0) return;
      final key = line.substring(0, separator).trim();
      final value = line.substring(separator + 1).trim();
      switch (key) {
        case 'frame':
          frames = int.tryParse(value) ?? frames;
        case 'fps':
          fps = double.tryParse(value) ?? fps;
        case 'speed':
          speed = double.tryParse(value.replaceAll('x', '')) ?? speed;
        case 'out_time_us':
          outTimeUs = int.tryParse(value) ?? outTimeUs;
        case 'out_time_ms': // older builds report milliseconds
          outTimeUs = (int.tryParse(value) ?? 0) * 1000;
        case 'out_time': // HH:MM:SS.ffffff fallback
          outTimeUs = _parseOutTime(value) ?? outTimeUs;
        case 'progress':
          emit();
        default:
          break;
      }
    }).asFuture<void>();

    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(log)
        .asFuture<void>();

    final exitCode = await process.exitCode;
    await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
    stopwatch.stop();
    _process = null;

    if (exitCode == 0) {
      var bytes = 0;
      try {
        final file = File(job.outputPath);
        if (file.existsSync()) bytes = file.lengthSync();
      } catch (_) {
        // Non-fatal: the caller can stat the file itself.
      }
      return RenderOutcome(
        succeeded: true,
        exitCode: exitCode,
        outputPath: job.outputPath,
        elapsed: stopwatch.elapsed,
        bytesWritten: bytes,
      );
    }

    final tail = logLines.length > 12
        ? logLines.sublist(logLines.length - 12).join('\n')
        : logLines.join('\n');
    return RenderOutcome(
      succeeded: false,
      exitCode: exitCode,
      outputPath: job.outputPath,
      elapsed: stopwatch.elapsed,
      errorMessage:
          _cancelled ? 'Export cancelled' : 'ffmpeg exited with $exitCode\n$tail',
    );
  }

  /// Stops the running process. Export files are re-creatable, so a hard kill
  /// is the right behaviour (a half-written mp4 must never be shown as done).
  Future<void> cancel() async {
    final process = _process;
    if (process == null) return;
    _cancelled = true;
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {
      try {
        process.kill();
      } catch (_) {
        // Already gone.
      }
    }
  }

  static int? _parseOutTime(String value) {
    final match =
        RegExp(r'^(\d+):(\d{2}):(\d{2}(?:\.\d+)?)$').firstMatch(value);
    if (match == null) return null;
    final hours = int.parse(match.group(1)!);
    final minutes = int.parse(match.group(2)!);
    final seconds = double.parse(match.group(3)!);
    return ((hours * 3600 + minutes * 60 + seconds) * 1000000).round();
  }
}

// -----------------------------------------------------------------------------
// Availability probe
// -----------------------------------------------------------------------------

/// Result of probing the FFmpeg host (logs + settings/diagnostics UI).
@immutable
class FfmpegAvailability {
  const FfmpegAvailability({
    required this.binary,
    required this.supported,
    this.version = '',
    this.message = '',
  });

  /// Binary name/path that was probed.
  final String binary;

  /// `true` when the binary exists *and* is new enough for the render graph.
  final bool supported;

  /// Parsed `major.minor` (e.g. `6.1`); empty when unparseable.
  final String version;

  /// Human-readable reason (always set).
  final String message;

  @override
  String toString() => 'FfmpegAvailability($binary, supported: $supported'
      '${version.isEmpty ? '' : ', $version'}) - $message';
}

/// Parses `ffmpeg version 6.1.1-...` into `[major, minor]`.
/// Old nightlies (`ffmpeg version N-55702-g920046a`) return `null`.
List<int>? parseFfmpegVersion(String text) {
  final match = RegExp(r'version\s+(\d+)\.(\d+)').firstMatch(text);
  if (match == null) return null;
  return <int>[int.parse(match.group(1)!), int.parse(match.group(2)!)];
}

bool _versionAtLeast(List<int> version, int major, int minor) =>
    version[0] > major || (version[0] == major && version[1] >= minor);

// -----------------------------------------------------------------------------
// Renderer
// -----------------------------------------------------------------------------

/// FFmpeg implementation of [RenderBackend]: builds the graph and optionally
/// runs it.
///
/// ```dart
/// final renderer = FfmpegRenderer(keepScript: true);
/// final engine = ExportEngine();
/// final plan = engine.plan(
///   source: ControllerProjectSource(controller: timelineController),
///   settings: ExportSettings.balanced1080p30,
///   outputPath: '/exports/holiday.mp4',
/// );
/// final outcome = await engine.run(renderer,
///     source: plan.source, settings: plan.settings);
/// ```
class FfmpegRenderer implements RenderBackend {
  FfmpegRenderer({
    this.ffmpegBinary = 'ffmpeg',
    this.keepScript = false,
    this.scriptPath,
  });

  /// Binary name or absolute path.
  final String ffmpegBinary;

  /// Also write the shell script next to the output - handy for bug reports
  /// and for reproducing a render on a desktop machine.
  final bool keepScript;

  /// Script destination; defaults to `<output>.sh`.
  final String? scriptPath;

  FfmpegProcessRunner? _runner;

  @override
  String get name => 'ffmpeg';

  /// Options used by the generated graph (`force_divisible_by`, amix
  /// `normalize`, overlay `eof_action`, `-filter_complex_threads`,
  /// `-progress pipe:1`) all exist in FFmpeg 4.4 and newer.
  static const String minimumVersion = '4.4';

  @override
  Future<bool> isAvailable() async => (await probe()).supported;

  /// Full probe (version + human-readable reason) for the settings screen.
  ///
  /// Runs `-version` on its own - every FFmpeg release supports that flag,
  /// unlike `-hide_banner`, so even a 2013 build answers and can be reported
  /// as *too old* instead of silently missing.
  Future<FfmpegAvailability> probe() async {
    try {
      final result = await Process.run(ffmpegBinary, <String>['-version']);
      final output = '${result.stdout}\n${result.stderr}'.trim();
      final firstLine = output.isEmpty ? '' : output.split('\n').first.trim();
      final version = parseFfmpegVersion(firstLine);
      if (result.exitCode != 0 || version == null) {
        return FfmpegAvailability(
          binary: ffmpegBinary,
          supported: false,
          message: firstLine.isEmpty
              ? 'FFmpeg did not report a version (exit code ${result.exitCode}).'
              : 'Unrecognized FFmpeg version line: "$firstLine" - '
                  'install FFmpeg $minimumVersion or newer.',
        );
      }
      final versionText = '${version[0]}.${version[1]}';
      final supported = _versionAtLeast(version, 4, 4);
      return FfmpegAvailability(
        binary: ffmpegBinary,
        supported: supported,
        version: versionText,
        message: supported
            ? 'FFmpeg $versionText'
            : 'FFmpeg $versionText is older than $minimumVersion '
                '(force_divisible_by / normalize / eof_action are missing).',
      );
    } catch (error) {
      return FfmpegAvailability(
        binary: ffmpegBinary,
        supported: false,
        message: 'FFmpeg could not be started: $error',
      );
    }
  }

  @override
  Future<void> cancel() async {
    await _runner?.cancel();
  }

  /// Builds the job for [plan] without starting anything (unit tests, script
  /// export, graph inspection).
  FfmpegRenderJob buildJob(ExportPlan plan, {String? outputPath}) {
    final destination =
        outputPath ?? plan.outputPath ?? plan.defaultOutputFileName;
    return _GraphAssembler(plan).assemble(destination);
  }

  @override
  Future<RenderOutcome> render(
    ExportPlan plan, {
    void Function(ExportProgress progress)? onProgress,
    void Function(String line)? onLog,
  }) async {
    if (!plan.hasVisualContent) {
      return RenderOutcome.failure(
          'Nothing to render: the plan has no visual layers.');
    }

    final destination = plan.outputPath ?? plan.defaultOutputFileName;
    final job = buildJob(plan, outputPath: destination);

    onLog?.call('MOpus Studio render: ${plan.describe()}');
    onLog?.call(job.commandLine);

    if (keepScript) {
      try {
        await File(scriptPath ?? '$destination.sh')
            .writeAsString(job.toShellScript());
      } catch (error) {
        onLog?.call('Could not write render script: $error');
      }
    }

    final runner = FfmpegProcessRunner(binary: ffmpegBinary);
    _runner = runner;
    try {
      return await runner.run(job, onProgress: onProgress, onLog: onLog);
    } finally {
      _runner = null;
    }
  }
}
