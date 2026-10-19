// =============================================================================
// MOpus Studio - lib/engine/export_engine.dart
// -----------------------------------------------------------------------------
// Offline rendering engine - planner half (Module 3).
//
// Responsibilities:
//   * Describe export targets (720p / 1080p / 4K at 30 or 60 fps) with a
//     bitrate ladder tuned for 2GB-RAM phones.
//   * Read the live editor state through a tiny read-only interface
//     ([RenderProjectSource]) so the planner never mutates a project and can
//     run headless (CLI / CI) against a fake source.
//   * Produce a deterministic [ExportPlan]: duration, frame count, size
//     estimate, proxy-cache strategy and per-layer warnings.
//
// The FFmpeg command / filter graph construction lives in
// `ffmpeg_renderer.dart`. Keeping planner and backend apart means the planner
// is unit-testable without a process, a file system or a platform channel.
// =============================================================================

import 'package:flutter/foundation.dart';

import '../controllers/timeline_controller.dart';
import '../models/keyframe_model.dart';
import '../models/layer_model.dart';
import 'animation_interpolator.dart';
import 'transform_matrix_engine.dart';

// -----------------------------------------------------------------------------
// Export targets
// -----------------------------------------------------------------------------

/// Export canvas sizes, ordered lightest -> heaviest so the UI can bind them
/// straight onto a segmented control.
enum ExportResolution {
  hd720(1280, 720, '720p'),
  fullHd1080(1920, 1080, '1080p'),
  uhd4k(3840, 2160, '4K');

  const ExportResolution(this.width, this.height, this.label);

  final int width;
  final int height;
  final String label;

  /// Total pixels - the planner scales the bitrate ladder with this.
  int get pixelCount => width * height;

  /// FFmpeg `-s` argument (`1280x720`).
  String get sizeArgument => '${width}x$height';

  /// Aspect ratio (16:9 for every preset; kept for future vertical targets).
  double get aspectRatio => width / height;

  @override
  String toString() => '$label (${width}x$height)';
}

/// Everything the renderer needs to know about the target file.
///
/// Values are deliberately conservative for 2GB devices: two encoder threads,
/// a single filter thread and `veryfast` - all three parameters trade a few
/// percent of compression for a large drop in peak memory.
@immutable
class ExportSettings {
  const ExportSettings({
    this.resolution = ExportResolution.fullHd1080,
    this.frameRate = 30,
    this.videoBitrateKbps = 12000,
    this.audioBitrateKbps = 192,
    this.audioSampleRate = 48000,
    this.encoderPreset = 'veryfast',
    this.crf,
    this.threads = 2,
    this.filterThreads = 1,
    this.fastStart = true,
    this.useProxyCache = true,
    this.bakeSubdivisions = 6,
    this.textFontFile,
    this.textFontSize = 96,
    this.backgroundColorHex = '0x050505',
  })  : assert(frameRate == 30 || frameRate == 60,
            'Only 30 and 60 fps export targets are supported.'),
        assert(bakeSubdivisions >= 1, 'bakeSubdivisions must be >= 1'),
        assert(threads >= 1, 'threads must be >= 1'),
        assert(filterThreads >= 1, 'filterThreads must be >= 1');

  // -- Static presets ---------------------------------------------------------

  /// Safe default for 2GB phones: 720p30, proxies on, ~5 Mbps.
  static const ExportSettings lowRam720p30 = ExportSettings(
    resolution: ExportResolution.hd720,
    frameRate: 30,
    videoBitrateKbps: 5000,
    crf: 23,
    threads: 2,
    filterThreads: 1,
    useProxyCache: true,
  );

  /// The everyday target for mid-range hardware: 1080p30 at ~12 Mbps.
  static const ExportSettings balanced1080p30 = ExportSettings(
    resolution: ExportResolution.fullHd1080,
    frameRate: 30,
    videoBitrateKbps: 12000,
    crf: 22,
    threads: 2,
    filterThreads: 1,
    useProxyCache: true,
  );

  /// Social-friendly smooth motion; only for devices with headroom.
  static const ExportSettings smooth1080p60 = ExportSettings(
    resolution: ExportResolution.fullHd1080,
    frameRate: 60,
    videoBitrateKbps: 20000,
    crf: 22,
    threads: 4,
    filterThreads: 1,
    useProxyCache: true,
  );

  /// Master output (desktop / export queue), 4K30 high bitrate.
  static const ExportSettings master4k30 = ExportSettings(
    resolution: ExportResolution.uhd4k,
    frameRate: 30,
    videoBitrateKbps: 45000,
    crf: 20,
    threads: 4,
    filterThreads: 1,
    useProxyCache: true,
  );

  // -- Fields -----------------------------------------------------------------

  /// Canvas size of the rendered file.
  final ExportResolution resolution;

  /// 30 or 60.
  final int frameRate;

  /// Average video bitrate in kbit/s (used when [crf] is `null`, and always
  /// emitted as `-maxrate`/`-bufsize` guidance in bitrate mode).
  final int videoBitrateKbps;

  /// AAC bitrate in kbit/s.
  final int audioBitrateKbps;

  /// AAC sample rate; 48 kHz keeps SmartTV / social re-encodes clean.
  final int audioSampleRate;

  /// x264 speed presets: `ultrafast`, `veryfast`, `faster`, `fast`, `medium`.
  final String encoderPreset;

  /// Constant Rate Factor (18..28 sane). `null` = fixed bitrate mode.
  final int? crf;

  /// Encoder threads. Keep at 2 on low-RAM devices.
  final int threads;

  /// `-filter_complex_threads`. 1 avoids per-thread frame buffers in the
  /// filter graph - the single biggest memory win on 2GB phones.
  final int filterThreads;

  /// `+faststart`: moves the moov atom to the front so players can stream.
  final bool fastStart;

  /// Transcode sources to 540p proxies before the final pass.
  final bool useProxyCache;

  /// Number of time slices used to bake animated opacity/scale into the
  /// filter graph (see `ffmpeg_renderer.dart`). Higher = smoother, more
  /// graph nodes.
  final int bakeSubdivisions;

  /// Optional font file for text layers (`drawtext=fontfile=`). When `null`
  /// the renderer emits `font='Sans'`, which needs fontconfig (Linux/macOS).
  final String? textFontFile;

  /// Text size in canvas pixels before the layer's own scale transform.
  final int textFontSize;

  /// Canvas background as a `0xRRGGBB` colour (brand Jet Black by default).
  final String backgroundColorHex;

  // -- Derived ----------------------------------------------------------------

  /// Rough bit budget of one second of output, in bytes.
  double get bytesPerSecond =>
      (videoBitrateKbps + audioBitrateKbps) * 1000 / 8.0;

  String describe() =>
      '${resolution.label} @ ${frameRate}fps, '
      '${crf != null ? 'crf $crf' : '${videoBitrateKbps} kbps'}, '
      '${encoderPreset}';

  /// Soft validation: returns human-readable warnings instead of throwing, so
  /// the export sheet can show them and still let the user continue.
  List<String> validate({int deviceRamMb = 2048}) {
    final warnings = <String>[];
    final lowMemory = deviceRamMb <= 2048;
    if (lowMemory && resolution == ExportResolution.uhd4k) {
      warnings.add(
          '4K export on a ${deviceRamMb}MB device will likely fail - 1080p is '
          'the safe target.');
    }
    if (resolution == ExportResolution.uhd4k && frameRate == 60) {
      warnings.add('4K60 doubles encoder load for no visible gain on phones.');
    }
    if (lowMemory && threads > 2) {
      warnings.add('More than 2 encoder threads raises peak memory on '
          '${deviceRamMb}MB devices.');
    }
    if (lowMemory && !useProxyCache) {
      warnings.add(
          'Proxy cache disabled: decoding full-resolution sources directly '
          'can stutter or OOM on 2GB devices.');
    }
    if (crf != null && (crf! < 16 || crf! > 30)) {
      warnings.add('CRF ${crf} is outside the useful range (18..28).');
    }
    return warnings;
  }
}

// -----------------------------------------------------------------------------
// Proxy cache
// -----------------------------------------------------------------------------

/// Proxy-first rendering: source clips are transcoded once into a light
/// intermediate (default 960x540) and the final pass composites those proxies.
/// This turns per-frame decode cost from "full source" into "proxy", which is
/// what makes 1080p30 export viable on 2GB phones.
///
/// Entries are keyed by source path + size + mtime, so re-exporting an
/// unchanged project is a byte-for-byte cache hit.
@immutable
class ProxyCachePlan {
  const ProxyCachePlan({
    this.width = 960,
    this.height = 540,
    this.crf = 26,
    this.cacheDirectoryName = 'mopus_proxy_cache',
  })  : assert(width > 0 && height > 0),
        assert(crf >= 18 && crf <= 32);

  /// Proxy canvas - 540p is the sweet spot for 1080p finals on mobile.
  final int width;
  final int height;

  /// Proxy CRF; proxies are throwaway, so quality can dip.
  final int crf;

  /// Sub-directory name under the platform temp/cache root. The service layer
  /// resolves it against `getTemporaryDirectory()` (or `%TEMP%` on desktop).
  final String cacheDirectoryName;

  String get sizeArgument => '${width}x$height';

  /// Deterministic cache file name for [sourcePath]. [fileSizeBytes] and
  /// [modifiedMillis] come from the call site so this class stays free of
  /// `dart:io`.
  String entryFor(
    String sourcePath, {
    int fileSizeBytes = 0,
    int modifiedMillis = 0,
  }) {
    final rawName = sourcePath.split(RegExp(r'[/\\]')).last;
    final safeName = rawName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '$safeName.$fileSizeBytes.$modifiedMillis.proxy.mp4';
  }

  @override
  String toString() => 'ProxyCachePlan($sizeArgument, crf $crf)';
}

// -----------------------------------------------------------------------------
// Read-only project access
// -----------------------------------------------------------------------------

/// Procedural shape description used by shape layers.
///
/// Module 1 stored layer *types* but no shape geometry yet (the media pipeline
/// arrives with Module 4), so the renderer uses brand-coloured defaults and
/// lets the app supply real parameters through [RenderProjectSource].
@immutable
class ShapeSpec {
  const ShapeSpec({
    this.colorHex = '0xFF6B00',
    this.widthFraction = 0.4,
    this.heightFraction = 0.25,
    this.opacity = 1.0,
  });

  /// `0xRRGGBB` (default: Electric Orange).
  final String colorHex;

  /// Rectangle size as a fraction of the canvas (0..1).
  final double widthFraction;
  final double heightFraction;

  /// 0..1 fill alpha.
  final double opacity;

  @override
  String toString() => 'ShapeSpec($colorHex, $widthFraction x $heightFraction)';
}

/// Everything the render planner needs from an editor session.
///
/// Intentionally tiny and read-only: the exporter can never mutate a project,
/// and headless renderers (CI batch exports, tests) can implement this against
/// a JSON document instead of a live controller.
abstract interface class RenderProjectSource {
  /// Layer stack; index 0 is the bottom layer.
  List<Layer> get layers;

  /// Timeline length in seconds (> 0; the caller clamps degenerate projects).
  double get duration;

  /// Project frame rate; [ExportSettings.frameRate] wins at render time.
  int get frameRate;

  /// Media path for [layer]. `''` means "procedural or unknown"; the planner
  /// then skips the layer instead of emitting a broken graph.
  String assetPathFor(Layer layer);

  /// Keyframe track for one property ([KeyframeProperty] constants).
  List<Keyframe> keyframesFor(String layerId, String propertyName);

  /// Adjustment effect assigned to a layer (neutral for non-adjustment ones).
  AdjustmentEffect adjustmentEffectOf(String layerId);

  /// Layer lookup by id.
  Layer? layerById(String? id);

  /// Stack index of the layer (0 = bottom); `-1` when unknown.
  int indexOfLayer(String layerId);

  /// World (parent-composed) transform at an absolute timeline time.
  LayerTransform worldTransformAt(Layer layer, double time);

  /// Opacity at an absolute timeline time, clamped to 0..1.
  double opacityAt(Layer layer, double time);

  /// Shape parameters for procedural shape layers.
  ShapeSpec shapeSpecFor(Layer layer);
}

/// Interpolator-backed base implementation for sources that are not a live
/// [TimelineController] (CLI renders, tests, imported projects).
///
/// The math is identical to the controller's `resolveWorldTransform`: Module 2
/// interpolation per property, then [LayerTransform.compose] up the parent
/// chain (null objects), exactly like the preview's hit-testing path.
abstract class KeyframeProjectSource implements RenderProjectSource {
  const KeyframeProjectSource();

  @override
  LayerTransform worldTransformAt(Layer layer, double time) {
    var result = _localTransformAt(layer, time);
    var parent = layerById(layer.parentId);
    var guard = 0;
    while (parent != null && guard++ < 64) {
      result = LayerTransform.compose(_localTransformAt(parent, time), result);
      parent = layerById(parent.parentId);
    }
    return result;
  }

  LayerTransform _localTransformAt(Layer layer, double time) =>
      AnimationInterpolator.transformAt(
        base: layer.transform,
        time: time,
        positionTrack: keyframesFor(layer.id, KeyframeProperty.position),
        scaleTrack: keyframesFor(layer.id, KeyframeProperty.scale),
        rotationTrack: keyframesFor(layer.id, KeyframeProperty.rotation),
      );

  @override
  double opacityAt(Layer layer, double time) => AnimationInterpolator.opacityAt(
        layer.opacity,
        keyframesFor(layer.id, KeyframeProperty.opacity),
        time,
      );

  @override
  AdjustmentEffect adjustmentEffectOf(String layerId) =>
      AdjustmentEffect.neutral;

  @override
  ShapeSpec shapeSpecFor(Layer layer) => const ShapeSpec();
}

/// Live-editor adapter: wraps a [TimelineController] (and optionally the
/// Module 2 [AdjustmentResolver]) so the export reads exactly what the preview
/// shows.
class ControllerProjectSource extends KeyframeProjectSource {
  ControllerProjectSource({
    required this.controller,
    this.adjustments,
    this.assetPathResolver,
    this.shapeSpecResolver,
    this.durationOverride,
  });

  final TimelineController controller;

  /// Owns the per-adjustment-layer effects (Module 2). When `null`, adjustment
  /// layers export as neutral.
  final AdjustmentResolver? adjustments;

  /// App-level media binding. Until the media pipeline lands most projects
  /// have no paths; the planner then reports those layers as skipped.
  final String Function(Layer layer)? assetPathResolver;

  /// Optional shape geometry provider (falls back to [ShapeSpec] defaults).
  final ShapeSpec Function(Layer layer)? shapeSpecResolver;

  /// Explicit timeline length; when `null`/non-positive the controller's
  /// project duration is used.
  final double? durationOverride;

  @override
  List<Layer> get layers => controller.layers;

  @override
  double get duration {
    final explicit = durationOverride;
    if (explicit != null && explicit > 0) return explicit;
    return controller.projectDuration;
  }

  @override
  int get frameRate => controller.frameRate;

  @override
  String assetPathFor(Layer layer) => assetPathResolver?.call(layer) ?? '';

  @override
  List<Keyframe> keyframesFor(String layerId, String propertyName) =>
      controller.keyframesFor(layerId, propertyName);

  @override
  AdjustmentEffect adjustmentEffectOf(String layerId) =>
      adjustments?.effectOf(layerId) ?? AdjustmentEffect.neutral;

  @override
  Layer? layerById(String? id) => controller.layerById(id);

  @override
  int indexOfLayer(String layerId) => controller.indexOfLayer(layerId);

  // Preview parity: delegate to the controller's own resolvers so exported
  // frames cannot drift from what the user scrubbed.
  @override
  LayerTransform worldTransformAt(Layer layer, double time) =>
      controller.resolveWorldTransform(layer, atTime: time);

  @override
  double opacityAt(Layer layer, double time) =>
      controller.resolveOpacity(layer, atTime: time);

  @override
  ShapeSpec shapeSpecFor(Layer layer) =>
      shapeSpecResolver?.call(layer) ?? const ShapeSpec();
}

// -----------------------------------------------------------------------------
// Plan / progress / backend contract
// -----------------------------------------------------------------------------

/// Immutable description of one export run: the (read-only) project plus
/// everything a backend needs to produce the command and the output file.
@immutable
class ExportPlan {
  const ExportPlan({
    required this.source,
    required this.settings,
    required this.durationSeconds,
    required this.frameCount,
    required this.estimatedBytes,
    required this.visualLayerIds,
    required this.audioLayerIds,
    required this.skippedLayerIds,
    required this.warnings,
    this.proxyPlan,
    this.outputPath,
  });

  final RenderProjectSource source;
  final ExportSettings settings;

  /// Clamped timeline length actually rendered.
  final double durationSeconds;

  /// `ceil(duration * fps)`.
  final int frameCount;

  /// Rough output size from the bitrate ladder (what the UI shows pre-export).
  final int estimatedBytes;

  /// Bottom-to-top render order (stack index 0 first). Includes adjustment
  /// layers: they emit no stream but define where the filter pass starts.
  final List<String> visualLayerIds;

  /// Audio layers that will be mixed down.
  final List<String> audioLayerIds;

  /// Layers that will not appear: missing media binding or hidden.
  final List<String> skippedLayerIds;

  /// Memory / settings / content warnings to surface before starting.
  final List<String> warnings;

  /// `null` when proxy caching is disabled in [settings].
  final ProxyCachePlan? proxyPlan;

  /// Explicit destination; `null` lets the backend derive a file name from
  /// [defaultOutputFileName].
  final String? outputPath;

  bool get hasVisualContent => visualLayerIds.isNotEmpty;
  bool get hasAudio => audioLayerIds.isNotEmpty;

  /// `mopus_export_1080p_30fps.mp4`.
  String get defaultOutputFileName {
    final label = settings.resolution.label.replaceAll(' ', '');
    return 'mopus_export_${label}_${settings.frameRate}fps.mp4';
  }

  String describe() => '${settings.describe()}, '
      '${frameCount} frames (${durationSeconds.toStringAsFixed(2)}s), '
      '~${(estimatedBytes / (1024 * 1024)).toStringAsFixed(1)} MB, '
      '${visualLayerIds.length} visual / ${audioLayerIds.length} audio layers'
      '${proxyPlan == null ? '' : ', proxies on'}';

  @override
  String toString() => 'ExportPlan(${describe()})';
}

/// Progress snapshot emitted while a backend encodes.
@immutable
class ExportProgress {
  const ExportProgress({
    required this.fraction,
    required this.encodedFrames,
    required this.totalFrames,
    this.fps = 0.0,
    this.speed = 0.0,
    this.elapsed = Duration.zero,
  });

  /// 0..1, clamped.
  final double fraction;
  final int encodedFrames;
  final int totalFrames;

  /// Encoder throughput reported by FFmpeg (`fps=`).
  final double fps;

  /// Speed factor reported by FFmpeg (`speed=2.1x` -> `2.1`).
  final double speed;

  /// Wall-clock time since the render started.
  final Duration elapsed;

  /// Linear ETA from the current fraction; [Duration.zero] when unknown.
  Duration get estimatedRemaining {
    if (fraction <= 0.0 || fraction >= 1.0 || elapsed.inMilliseconds <= 0) {
      return Duration.zero;
    }
    final totalMs = elapsed.inMilliseconds / fraction;
    return Duration(milliseconds: (totalMs - elapsed.inMilliseconds).round());
  }

  String describe() => '${(fraction * 100).toStringAsFixed(1)}% '
      '($encodedFrames/$totalFrames frames @ ${fps.toStringAsFixed(1)} fps)';

  @override
  String toString() => 'ExportProgress(${describe()})';
}

/// Result of one render run.
@immutable
class RenderOutcome {
  const RenderOutcome({
    required this.succeeded,
    required this.exitCode,
    required this.outputPath,
    required this.elapsed,
    this.bytesWritten = 0,
    this.errorMessage,
  });

  /// Builds a failure without a process ever starting (missing binary, bad
  /// plan, cancelled run).
  factory RenderOutcome.failure(
    String message, {
    int exitCode = -1,
    String outputPath = '',
  }) =>
      RenderOutcome(
        succeeded: false,
        exitCode: exitCode,
        outputPath: outputPath,
        elapsed: Duration.zero,
        errorMessage: message,
      );

  final bool succeeded;
  final int exitCode;
  final String outputPath;
  final Duration elapsed;

  /// Size of the produced file, when known.
  final int bytesWritten;

  /// `null` on success.
  final String? errorMessage;

  String describe() => succeeded
      ? 'OK ${(bytesWritten / (1024 * 1024)).toStringAsFixed(1)} MB in '
          '${elapsed.inSeconds}s -> $outputPath'
      : 'FAILED ($exitCode): ${errorMessage ?? 'unknown error'}';

  @override
  String toString() => 'RenderOutcome(${describe()})';
}

/// A render backend turns a plan into bytes.
///
/// `ffmpeg_renderer.dart` ships the FFmpeg implementation, tests use a fake,
/// and the AI staging layer never touches this contract - that separation is
/// what keeps offline editing independent from future network features.
abstract interface class RenderBackend {
  /// Diagnostics name (`ffmpeg`, `script`, `fake`, ...).
  String get name;

  /// `false` when the host has no usable binary/libraries; the UI then shows
  /// an install hint instead of failing mid-export.
  Future<bool> isAvailable();

  /// Runs the plan to completion.
  ///
  /// [onProgress] receives monotonically increasing snapshots, [onLog] raw
  /// stderr lines for the export log sheet.
  Future<RenderOutcome> render(
    ExportPlan plan, {
    void Function(ExportProgress progress)? onProgress,
    void Function(String line)? onLog,
  });

  /// Cancels a running render; safe to call when idle.
  Future<void> cancel();
}

// -----------------------------------------------------------------------------
// Planner
// -----------------------------------------------------------------------------

/// Stateless planner: turns editor state into an [ExportPlan].
///
/// Running the plan is the backend's job, which keeps this class usable from
/// the UI isolate, from a test and from a headless CLI without changes.
class ExportEngine {
  const ExportEngine();

  /// Builds a plan for [source] under [settings].
  ExportPlan plan({
    required RenderProjectSource source,
    required ExportSettings settings,
    String? outputPath,
  }) {
    final rawDuration = source.duration;
    final duration =
        rawDuration.isFinite && rawDuration > 0 ? rawDuration : 1.0;

    final visual = <String>[];
    final audio = <String>[];
    final skipped = <String>[];

    for (final layer in source.layers) {
      if (!layer.isVisible) {
        skipped.add(layer.id);
        continue;
      }
      switch (layer.type) {
        case LayerType.nullObject:
          continue; // transform-only helper: no pixels, no stream
        case LayerType.audio:
          if (source.assetPathFor(layer).isEmpty) {
            skipped.add(layer.id);
          } else {
            audio.add(layer.id);
          }
        case LayerType.video:
          if (source.assetPathFor(layer).isEmpty) {
            skipped.add(layer.id);
          } else {
            visual.add(layer.id);
          }
        case LayerType.text:
        case LayerType.shape:
          visual.add(layer.id); // procedural: no media needed
        case LayerType.adjustmentLayer:
          // Emits no stream of its own; the renderer folds it into every
          // visual layer below its stack index.
          visual.add(layer.id);
      }
    }

    final frameCount = (duration * settings.frameRate).ceil();
    final estimatedBytes = (settings.bytesPerSecond * duration).round();

    final warnings = <String>[...settings.validate()];
    if (skipped.isNotEmpty) {
      warnings.add('${skipped.length} layer(s) skipped (hidden or without '
          'media binding).');
    }
    if (visual.isEmpty) {
      warnings.add('No visual layers - the export would be a blank canvas.');
    }
    if (visual.length > 12) {
      warnings.add('${visual.length} visual layers: above ~12 the filter graph '
          'starts to cost more than the encoder on 2GB devices.');
    }

    return ExportPlan(
      source: source,
      settings: settings,
      durationSeconds: duration,
      frameCount: frameCount,
      estimatedBytes: estimatedBytes,
      visualLayerIds: List<String>.unmodifiable(visual),
      audioLayerIds: List<String>.unmodifiable(audio),
      skippedLayerIds: List<String>.unmodifiable(skipped),
      warnings: List<String>.unmodifiable(warnings),
      proxyPlan: settings.useProxyCache ? const ProxyCachePlan() : null,
      outputPath: outputPath,
    );
  }

  /// Convenience: plan and hand the result straight to [backend].
  Future<RenderOutcome> run(
    RenderBackend backend, {
    required RenderProjectSource source,
    required ExportSettings settings,
    String? outputPath,
    void Function(ExportProgress progress)? onProgress,
    void Function(String line)? onLog,
  }) =>
      backend.render(
        plan(source: source, settings: settings, outputPath: outputPath),
        onProgress: onProgress,
        onLog: onLog,
      );
}
