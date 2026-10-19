// =============================================================================
// MOpus Studio - test/render_engine_test.dart
// -----------------------------------------------------------------------------
// Module 3 tests: FFmpeg expression builder, effects library, export planner,
// filter-graph generation and the AI staging bridge.
//
// The renderer is verified through its pure halves (`ExportEngine.plan` +
// `FfmpegRenderer.buildJob`), so the whole pipeline is testable without an
// FFmpeg binary, a device or a platform channel.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:mopus_studio/controllers/timeline_controller.dart';
import 'package:mopus_studio/engine/effects_library.dart';
import 'package:mopus_studio/engine/export_engine.dart';
import 'package:mopus_studio/engine/ffmpeg_renderer.dart';
import 'package:mopus_studio/engine/transform_matrix_engine.dart';
import 'package:mopus_studio/models/keyframe_model.dart';
import 'package:mopus_studio/models/layer_model.dart';
import 'package:mopus_studio/services/ai_integration_bridge.dart';

// -----------------------------------------------------------------------------
// Test doubles
// -----------------------------------------------------------------------------

/// Hand-built project source: no controller, no UI, fully deterministic.
class _FakeSource extends KeyframeProjectSource {
  _FakeSource({
    required this.layers,
    Map<String, String>? assets,
    Map<String, AdjustmentEffect>? effects,
    this.duration = 4.0,
    this.frameRateValue = 30,
    this.shapeSpec = const ShapeSpec(),
  })  : assets = assets ?? const <String, String>{},
        effects = effects ?? const <String, AdjustmentEffect>{};

  @override
  final List<Layer> layers;
  final Map<String, String> assets;
  final Map<String, AdjustmentEffect> effects;

  @override
  final double duration;

  final int frameRateValue;
  final ShapeSpec shapeSpec;

  final Map<String, List<Keyframe>> _tracks = <String, List<Keyframe>>{};

  /// Registers a keyframe track (`layerId::property` convention).
  void track(String layerId, String property, List<Keyframe> keyframes) {
    _tracks['$layerId::$property'] = keyframes;
  }

  @override
  int get frameRate => frameRateValue;

  @override
  String assetPathFor(Layer layer) => assets[layer.id] ?? '';

  @override
  List<Keyframe> keyframesFor(String layerId, String propertyName) =>
      _tracks['$layerId::$propertyName'] ?? const <Keyframe>[];

  @override
  AdjustmentEffect adjustmentEffectOf(String layerId) =>
      effects[layerId] ?? AdjustmentEffect.neutral;

  @override
  Layer? layerById(String? id) {
    for (final layer in layers) {
      if (layer.id == id) return layer;
    }
    return null;
  }

  @override
  int indexOfLayer(String layerId) {
    for (var i = 0; i < layers.length; i++) {
      if (layers[i].id == layerId) return i;
    }
    return -1;
  }

  @override
  ShapeSpec shapeSpecFor(Layer layer) => shapeSpec;
}

Keyframe _kf(String id, String property, double time, dynamic value,
        [String easing = 'linear']) =>
    Keyframe(
      id: id,
      propertyName: property,
      time: time,
      value: value,
      easingCurve: easing,
    );

/// Minimal staged caption provider used by the bridge tests.
final class _FakeCaptionService extends AiAutoCaptionService {
  _FakeCaptionService({this.transcribeResult = const <AiCaptionSegment>[]});

  final List<AiCaptionSegment> transcribeResult;
  int calls = 0;

  @override
  AiProviderConfig get config => const AiProviderConfig(
        name: 'fake-cloud',
        capability: AiCapability.autoCaptions,
        endpoint: 'https://example.invalid',
        model: 'fake-whisper',
        apiKey: 'secret',
      );

  @override
  bool get isConfigured => true;

  @override
  String get status => 'Ready (fake)';

  @override
  Future<AiJobResult> execute(AiJobRequest request) async => AiJobResult(
        requestId: request.requestId,
        capability: capability,
        succeeded: true,
        payload: <String, Object?>{'segments': transcribeResult.length},
      );

  @override
  Future<List<AiCaptionSegment>> transcribe(
    String mediaPath, {
    String? languageCode,
    bool wordLevelTimings = false,
  }) async {
    calls++;
    return transcribeResult;
  }
}

void main() {
  // ---------------------------------------------------------------------------
  // Expression builder
  // ---------------------------------------------------------------------------
  group('FfmpegExpressionBuilder', () {
    test('formats numbers without scientific notation', () {
      expect(ffmpegNumber(1.0), '1');
      expect(ffmpegNumber(-0.2), '-0.2');
      expect(ffmpegNumber(0.00001), '0.00001');
      expect(ffmpegNumber(double.nan), '0');
      expect(ffmpegNumber(double.infinity), '0');
    });

    test('collapses a constant curve to a number', () {
      final expression = FfmpegExpressionBuilder.piecewise(
        const <FfmpegKnot>[FfmpegKnot(0, 3), FfmpegKnot(2, 3)],
      );
      expect(expression, '3');
    });

    test('interpolates between knots and clamps at both ends', () {
      final expression = FfmpegExpressionBuilder.piecewise(
        const <FfmpegKnot>[FfmpegKnot(0, 0), FfmpegKnot(1, 2)],
      );
      // First segment clamps before t=0, default value holds after t=1.
      expect(expression, contains('max(t-0,0)'));
      expect(expression, contains('if(lt(t,1),'));
      expect(expression, endsWith('2'));
    });

    test('subdivides eased segments when sampling a track', () {
      final track = <Keyframe>[
        _kf('a', KeyframeProperty.position, 0.0, const Position(x: 0, y: 0),
            'easeIn'),
        _kf('b', KeyframeProperty.position, 1.0, const Position(x: 100, y: 0)),
      ];
      final knots = FfmpegExpressionBuilder.knotsFromTrack(
        track,
        extract: (value) => value is Position ? value.x : 0.0,
        subdivisionsPerSegment: 4,
      );
      expect(knots.length, 5);
      expect(knots.first.value, 0.0);
      expect(knots.last.value, 100.0);
      // Eased mid-sample (t=0.25) must sit *behind* the linear midpoint value.
      expect(knots[1].value, lessThan(25.0));
    });

    test('decimates long tracks to the knot cap', () {
      final track = <Keyframe>[
        for (var i = 0; i < 40; i++)
          _kf('k$i', KeyframeProperty.opacity, i.toDouble(), i / 39),
      ];
      final knots = FfmpegExpressionBuilder.knotsFromTrack(
        track,
        extract: (value) => (value as num).toDouble(),
        subdivisionsPerSegment: 4,
      );
      expect(knots.length, greaterThan(FfmpegExpressionBuilder.maxKnots));
      final expression = FfmpegExpressionBuilder.piecewise(knots);
      expect(expression, startsWith('if(lt(t,'));
      expect(expression, endsWith('1'));
    });

    test('quotes shell arguments safely', () {
      expect(shellQuote('ffmpeg'), 'ffmpeg');
      expect(shellQuote('C:\\My Files\\out.mp4'), "'C:\\My Files\\out.mp4'");
      expect(shellQuote("it's"), "'it'\"'\"'s'");
    });
  });

  // ---------------------------------------------------------------------------
  // Effects library
  // ---------------------------------------------------------------------------
  group('EffectsLibrary', () {
    test('joins filters in order and drops neutral effects', () {
      final chain = EffectsLibrary.chain(<VideoEffect>[
        ToneEffect(brightness: -0.2),
        SharpenEffect(amount: 0.0),
        GaussianBlurEffect(sigma: 4),
      ]);
      expect(
        chain,
        'eq=brightness=-0.2:contrast=1:saturation=1,gblur=sigma=4:steps=1',
      );
      expect(EffectsLibrary.chain(<VideoEffect>[ToneEffect()]), '');
    });

    test('converts an adjustment into tone/tint/blur filters', () {
      final effects = EffectsLibrary.fromEffect(const AdjustmentEffect(
        brightness: 0.2,
        contrast: 1.1,
        blurSigma: 3,
        temperature: 0.5,
      ));
      expect(effects.length, 3);
      final chain = EffectsLibrary.chain(effects);
      expect(chain, contains('eq=brightness=0.2'));
      expect(chain, contains('colorbalance'));
      expect(chain, contains('gblur=sigma=3:steps=1'));
      // Opacity is handled by the renderer's alpha path, not as a filter.
      expect(chain, isNot(contains('aa=')));
    });

    test('aggregate pass-through matches effect conversion', () {
      final aggregate = AdjustmentAggregate()
        ..combine(const AdjustmentEffect(brightness: 0.1))
        ..combine(const AdjustmentEffect(saturation: 0.5));
      final chain = EffectsLibrary.chainFromAggregate(aggregate);
      expect(chain, contains('brightness=0.1'));
      expect(chain, contains('saturation=0.5'));
    });

    test('motion blur overlay maps to tmix with trailing weights', () {
      expect(
        const MotionBlurOverlayEffect(frames: 3).toFfmpegFilter(),
        'tmix=frames=3',
      );
      final weights = MotionBlurOverlayEffect.trailingWeights(3);
      expect(weights.length, 3);
      expect(weights.reduce((a, b) => a + b), closeTo(1.0, 1e-9));
      expect(weights.last, greaterThan(weights.first));
      final weighted =
          MotionBlurOverlayEffect(frames: 3, weights: weights).toFfmpegFilter();
      expect(weighted, startsWith("tmix=frames=3:weights='"));
    });

    test('json round-trip keeps parameters', () {
      const effect = ToneEffect(brightness: 0.3, saturation: 1.4);
      final decoded = decodeVideoEffect(effect.toJson());
      expect(decoded, effect);
      expect(decodeVideoEffect(<String, dynamic>{'kind': 'unknown'}), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Export planner
  // ---------------------------------------------------------------------------
  group('ExportEngine.plan', () {
    test('classifies layers and estimates output size', () {
      final layers = <Layer>[
        Layer(id: 'v1', name: 'clip.mp4', type: LayerType.video, duration: 4),
        Layer(id: 'v2', name: 'missing.mp4', type: LayerType.video, duration: 4),
        Layer(id: 't1', name: 'Title', type: LayerType.text, duration: 2),
        Layer(id: 'n1', name: 'Rig', type: LayerType.nullObject, duration: 4),
        Layer(id: 'a1', name: 'music.mp3', type: LayerType.audio, duration: 4),
        Layer(
            id: 'adj',
            name: 'Grade',
            type: LayerType.adjustmentLayer,
            duration: 4),
      ];
      final source = _FakeSource(
        layers: layers,
        assets: <String, String>{'v1': 'clip.mp4', 'a1': 'music.mp3'},
      );
      final plan = const ExportEngine()
          .plan(source: source, settings: ExportSettings.lowRam720p30);

      expect(plan.visualLayerIds, <String>['v1', 't1', 'adj']);
      expect(plan.audioLayerIds, <String>['a1']);
      expect(plan.skippedLayerIds, <String>['v2']);
      expect(plan.frameCount, 120);
      expect(plan.estimatedBytes, ((5000 + 192) * 1000 / 8 * 4).round());
      expect(plan.proxyPlan, isNotNull);
      expect(plan.defaultOutputFileName, 'mopus_export_720p_30fps.mp4');
      expect(plan.warnings, isNotEmpty);
      expect(plan.hasVisualContent, isTrue);
      expect(plan.hasAudio, isTrue);
      expect(plan.describe(), contains('720p @ 30fps'));
    });

    test('falls back to a sane duration for empty projects', () {
      final plan = const ExportEngine().plan(
        source: _FakeSource(
            layers: const <Layer>[], duration: 0.0, frameRateValue: 60),
        settings: const ExportSettings(useProxyCache: false, frameRate: 60),
      );
      expect(plan.durationSeconds, 1.0);
      expect(plan.frameCount, 60);
      expect(plan.proxyPlan, isNull);
      expect(plan.visualLayerIds, isEmpty);
      expect(plan.hasVisualContent, isFalse);
      expect(plan.warnings.join(' '), contains('blank canvas'));
    });

    test('flags hidden layers as skipped', () {
      final source = _FakeSource(
        layers: <Layer>[
          Layer(
              id: 'v1',
              name: 'clip.mp4',
              type: LayerType.video,
              duration: 4,
              isVisible: false),
        ],
        assets: <String, String>{'v1': 'clip.mp4'},
      );
      final plan = const ExportEngine()
          .plan(source: source, settings: ExportSettings.lowRam720p30);
      expect(plan.visualLayerIds, isEmpty);
      expect(plan.skippedLayerIds, <String>['v1']);
    });

    test('warns about 4K and disabled proxies on low-memory devices', () {
      const settings = ExportSettings(
        resolution: ExportResolution.uhd4k,
        threads: 4,
        useProxyCache: false,
      );
      final warnings = settings.validate(deviceRamMb: 2048).join(' ');
      expect(warnings, contains('4K'));
      expect(warnings, contains('2048MB'));
      expect(warnings, contains('Proxy cache disabled'));
    });
  });

  // ---------------------------------------------------------------------------
  // Filter graph
  // ---------------------------------------------------------------------------
  group('FfmpegRenderer.buildJob', () {
    _FakeSource richSource() {
      final layers = <Layer>[
        Layer(id: 'v1', name: 'clip.mp4', type: LayerType.video, duration: 4),
        Layer(
            id: 'adj',
            name: 'Grade',
            type: LayerType.adjustmentLayer,
            duration: 4),
        Layer(id: 't1', name: "MO's Title", type: LayerType.text, duration: 4),
        Layer(
            id: 'a1',
            name: 'music.mp3',
            type: LayerType.audio,
            duration: 4,
            startTime: 2.0),
      ];
      return _FakeSource(
        layers: layers,
        assets: <String, String>{'v1': 'clip.mp4', 'a1': 'music.mp3'},
        effects: <String, AdjustmentEffect>{
          'adj': const AdjustmentEffect(brightness: 0.2, blurSigma: 2.0),
        },
      );
    }

    test('builds overlays, effects, text and audio into one graph', () {
      final plan = const ExportEngine()
          .plan(source: richSource(), settings: ExportSettings.lowRam720p30);
      final job = FfmpegRenderer().buildJob(plan);
      final graph = job.filterGraph!;

      expect(graph, contains('[0:v]format=rgba'));
      expect(graph,
          contains('scale=w=1280:h=720:force_original_aspect_ratio=decrease'));
      expect(graph, contains('overlay='));
      expect(graph, contains("x='(main_w-overlay_w)/2"));
      expect(graph, contains("enable='between(t,"));
      expect(graph, contains('eof_action=pass'));
      expect(graph, contains('eq=brightness=0.2'));
      expect(graph, contains('gblur=sigma=2:steps=1'));
      expect(graph, contains('drawtext='));
      expect(graph, contains("text='MO\\'s Title'"));
      expect(graph, contains('adelay=2000|2000'));
      expect(graph, contains('format=yuv420p'));
      expect(graph, contains('[vout]'));

      final command = job.arguments.join(' ');
      expect(command, contains('-stream_loop -1'));
      expect(command, contains('-preset veryfast'));
      expect(command, contains('-crf 23'));
      expect(command, contains('-movflags +faststart'));
      expect(command, contains('-filter_complex_threads 1'));
      expect(command, contains('-c:a aac'));
      expect(command, contains('-map [vout]'));
      expect(command, isNot(contains('-an')));
      expect(job.outputPath, 'mopus_export_720p_30fps.mp4');
      expect(job.commandLine, contains('ffmpeg'));
    });

    test('emits -an when the plan has no audio', () {
      final source = _FakeSource(
        layers: <Layer>[
          Layer(id: 'v1', name: 'clip.mp4', type: LayerType.video, duration: 4),
        ],
        assets: <String, String>{'v1': 'clip.mp4'},
      );
      final plan = const ExportEngine()
          .plan(source: source, settings: ExportSettings.lowRam720p30);
      final job = FfmpegRenderer().buildJob(plan);
      expect(job.arguments.join(' '), contains('-an'));
      expect(job.filterGraph, isNot(contains('amix')));
      expect(job.toShellScript(), startsWith('#!/usr/bin/env sh'));
    });

    test('bakes a linear opacity ramp as one smooth fade slice', () {
      final source = _FakeSource(
        layers: <Layer>[
          Layer(id: 'v1', name: 'clip.mp4', type: LayerType.video, duration: 4),
        ],
        assets: <String, String>{'v1': 'clip.mp4'},
      );
      source.track('v1', KeyframeProperty.opacity, <Keyframe>[
        _kf('k0', KeyframeProperty.opacity, 0.0, 0.0),
        _kf('k1', KeyframeProperty.opacity, 1.0, 1.0),
      ]);
      final plan = const ExportEngine()
          .plan(source: source, settings: ExportSettings.lowRam720p30);
      final graph = FfmpegRenderer().buildJob(plan).filterGraph!;
      expect(graph, contains('split=2'));
      expect(graph, contains('fade=t=in:st=0:d=1:alpha=1'));
      expect(graph, contains('concat=n=2:v=1:a=0'));
      expect(graph, contains('setpts=PTS+0/TB'));
    });

    test('bakes stepped alpha and scale for eased changes', () {
      final source = _FakeSource(
        layers: <Layer>[
          Layer(id: 'v1', name: 'clip.mp4', type: LayerType.video, duration: 4),
        ],
        assets: <String, String>{'v1': 'clip.mp4'},
      );
      source.track('v1', KeyframeProperty.opacity, <Keyframe>[
        _kf('k0', KeyframeProperty.opacity, 0.0, 1.0),
        _kf('k1', KeyframeProperty.opacity, 1.0, 0.5, 'easeInOut'),
      ]);
      source.track('v1', KeyframeProperty.scale, <Keyframe>[
        _kf('s0', KeyframeProperty.scale, 0.0, const Scale(), 'easeInOut'),
        _kf('s1', KeyframeProperty.scale, 2.0, const Scale(x: 1.5, y: 1.5)),
      ]);
      final plan = const ExportEngine().plan(
          source: source, settings: const ExportSettings(bakeSubdivisions: 3));
      final graph = FfmpegRenderer().buildJob(plan).filterGraph!;
      expect(graph, contains('colorchannelmixer=aa='));
      expect(graph, contains('scale=w=iw*');
      expect(graph, contains('pad=w=1920:h=1080'));
      expect(graph, contains('concat=n='));
      expect(graph, contains('trim=start='));
    });

    test('turns animated position into an overlay expression', () {
      final source = _FakeSource(
        layers: <Layer>[
          Layer(id: 'v1', name: 'clip.mp4', type: LayerType.video, duration: 4),
        ],
        assets: <String, String>{'v1': 'clip.mp4'},
      );
      source.track('v1', KeyframeProperty.position, <Keyframe>[
        _kf('p0', KeyframeProperty.position, 0.0, const Position()),
        _kf('p1', KeyframeProperty.position, 2.0, const Position(x: 100, y: -50)),
      ]);
      final plan = const ExportEngine()
          .plan(source: source, settings: ExportSettings.lowRam720p30);
      final graph = FfmpegRenderer().buildJob(plan).filterGraph!;
      expect(graph, contains('if(lt(t,'));
      expect(graph, contains('main_h-overlay_h'));
      expect(graph, contains('max(t-0,0)'));
    });

    test('rotation becomes a per-frame rotate filter', () {
      final source = _FakeSource(
        layers: <Layer>[
          Layer(id: 'v1', name: 'clip.mp4', type: LayerType.video, duration: 4),
        ],
        assets: <String, String>{'v1': 'clip.mp4'},
      );
      source.track('v1', KeyframeProperty.rotation, <Keyframe>[
        _kf('r0', KeyframeProperty.rotation, 0.0, const Rotation()),
        _kf('r1', KeyframeProperty.rotation, 2.0, const Rotation(degrees: 90)),
      ]);
      final plan = const ExportEngine()
          .plan(source: source, settings: ExportSettings.lowRam720p30);
      final graph = FfmpegRenderer().buildJob(plan).filterGraph!;
      expect(graph, contains("rotate=a='"));
      expect(graph, contains(':c=none'));
    });

    test('renders shape layers with the brand colour in canvas pixels', () {
      final source = _FakeSource(
        layers: <Layer>[
          Layer(id: 's1', name: 'Card', type: LayerType.shape, duration: 3),
        ],
        shapeSpec: const ShapeSpec(
          colorHex: '0xFF6B00',
          widthFraction: 0.5,
          heightFraction: 0.2,
        ),
      );
      final plan = const ExportEngine()
          .plan(source: source, settings: ExportSettings.lowRam720p30);
      final graph = FfmpegRenderer().buildJob(plan).filterGraph!;
      expect(graph, contains('drawbox='));
      expect(graph, contains('color=0xFF6B00'));
      expect(graph, contains('w=960'));
      expect(graph, contains('h=216'));
      expect(graph, contains('t=fill'));
    });
  });

  // ---------------------------------------------------------------------------
  // FFmpeg availability probe
  // ---------------------------------------------------------------------------
  group('Ffmpeg availability', () {
    test('parses version lines and rejects pre-4.4 nightlies', () {
      expect(parseFfmpegVersion('ffmpeg version 6.1.1-3ubuntu5 Copyright (c)'),
          <int>[6, 1]);
      expect(parseFfmpegVersion('ffmpeg version 4.4.2-0ubuntu0.22.04.1'),
          <int>[4, 4]);
      // The 2013 nightly found in Windows Python Scripts folders:
      expect(parseFfmpegVersion('ffmpeg version N-55702-g920046a'), isNull);
      expect(parseFfmpegVersion(''), isNull);
      expect(FfmpegRenderer.minimumVersion, '4.4');
    });

    test('availability results carry a reason for the UI', () {
      const availability = FfmpegAvailability(
        binary: 'ffmpeg',
        supported: false,
        message: 'FFmpeg 2.0 is older than 4.4',
      );
      expect(availability.supported, isFalse);
      expect(availability.toString(), contains('2.0'));
    });
  });

  // ---------------------------------------------------------------------------
  // AI staging bridge
  // ---------------------------------------------------------------------------
  group('AiIntegrationBridge', () {
    test('offline default returns value failures, never throws', () async {
      final bridge = AiIntegrationBridge();
      bridge.register(_FakeCaptionService());
      expect(bridge.isAvailable(AiCapability.autoCaptions), isFalse);

      final result = await bridge.execute(const AiJobRequest(
        capability: AiCapability.autoCaptions,
        inputPath: '/media/talk.mp4',
      ));
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, contains('not enabled'));
      expect(await bridge.tryTranscribe('/media/talk.mp4'), isNull);
      await bridge.dispose();
    });

    test('routes opted-in capabilities and normalises captions', () async {
      final bridge = AiIntegrationBridge(
        config: AiStagingConfig.offlineDefault.copyWith(
          allowNetwork: true,
          enabledCapabilities: const <AiCapability>{AiCapability.autoCaptions},
        ),
      );
      bridge.register(_FakeCaptionService(transcribeResult: <AiCaptionSegment>[
        const AiCaptionSegment(start: 4.0, end: 6.0, text: 'second'),
        const AiCaptionSegment(start: 0.5, end: 2.0, text: 'first'),
        const AiCaptionSegment(start: 2.0, end: 1.0, text: 'broken'),
        const AiCaptionSegment(start: 6.0, end: 7.0, text: '   '),
      ]));
      expect(bridge.isAvailable(AiCapability.autoCaptions), isTrue);

      final segments = await bridge.tryTranscribe('/media/talk.mp4');
      expect(segments, isNotNull);
      expect(segments!.length, 2);
      expect(segments.first.text, 'first');
      expect(segments.last.text, 'second');
      await bridge.dispose();
    });

    test('caption segments become ordinary text layers', () async {
      final controller = TimelineController();
      final bridge = AiIntegrationBridge();
      final created = bridge.applyCaptions(controller, <AiCaptionSegment>[
        const AiCaptionSegment(start: 0.0, end: 2.0, text: 'Hello world'),
        const AiCaptionSegment(start: 2.0, end: 3.5, text: 'Second line'),
      ]);

      expect(created, 2);
      expect(controller.layers.length, 2);
      expect(controller.layers.first.type, LayerType.text);
      expect(controller.layers.first.name, 'Hello world');
      expect(controller.layers.first.startTime, 0.0);
      expect(controller.layers.last.startTime, 2.0);
      controller.dispose();
      await bridge.dispose();
    });

    test('unconfigured providers are visible in the settings list', () async {
      final bridge = AiIntegrationBridge();
      bridge.register(NoopAiService(capability: AiCapability.voiceoverTts));

      final descriptors = bridge.describeProviders();
      expect(descriptors.length, AiCapability.values.length);
      final tts = descriptors
          .firstWhere((d) => d.capability == AiCapability.voiceoverTts);
      expect(tts.configured, isFalse);
      expect(tts.available, isFalse);
      expect(tts.status, contains('Not configured'));

      final result = await bridge.execute(const AiJobRequest(
        capability: AiCapability.voiceoverTts,
        inputPath: 'script.txt',
      ));
      expect(result.isFailure, isTrue);
      await bridge.dispose();
    });

    test('configuration never leaks the api key', () {
      const config = AiProviderConfig(
        name: 'fake-cloud',
        capability: AiCapability.autoCaptions,
        apiKey: 'super-secret-key',
      );
      expect(config.toString(), isNot(contains('super-secret-key')));
      expect(config.toString(), contains('<redacted>'));
      expect(config.withApiKey('').toString(), contains('<missing>'));
    });
  });
}
