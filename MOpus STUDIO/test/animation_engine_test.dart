// =============================================================================
// MOpus Studio - test/animation_engine_test.dart
// -----------------------------------------------------------------------------
// Module 2 unit tests: interpolation/easing, transform matrices + Null Object
// parenting, adjustment aggregation, motion blur and the playback controller's
// frame cache.
// =============================================================================

import 'package:flutter/widgets.dart' show Matrix4;
import 'package:flutter_test/flutter_test.dart';
import 'package:mopus_studio/controllers/animation_controller_extension.dart';
import 'package:mopus_studio/engine/animation_interpolator.dart';
import 'package:mopus_studio/engine/motion_blur_processor.dart';
import 'package:mopus_studio/engine/transform_matrix_engine.dart';
import 'package:mopus_studio/models/keyframe_model.dart';
import 'package:mopus_studio/models/layer_model.dart';

Keyframe _position(String id, double time, double x, double y,
        [String easing = 'linear']) =>
    Keyframe(
      id: id,
      propertyName: KeyframeProperty.position,
      time: time,
      value: Position(x: x, y: y),
      easingCurve: easing,
    );

List<Keyframe> _positionTrack() => <Keyframe>[
      _position('a', 0.0, 0.0, 0.0),
      _position('b', 2.0, 100.0, 50.0),
    ];

void main() {
  group('AnimationInterpolator', () {
    test('samples a linear position track at the midpoint', () {
      final value = AnimationInterpolator.positionAt(_positionTrack(), 1.0);
      expect(value, isNotNull);
      expect(value!.x, closeTo(50.0, 1e-9));
      expect(value.y, closeTo(25.0, 1e-9));
    });

    test('clamps before the first and after the last keyframe', () {
      final early = AnimationInterpolator.positionAt(_positionTrack(), -3.0);
      expect(early!.x, closeTo(0.0, 1e-9));
      final late = AnimationInterpolator.positionAt(_positionTrack(), 99.0);
      expect(late!.x, closeTo(100.0, 1e-9));
    });

    test('easeOut advances further than linear at the midpoint', () {
      final track = <Keyframe>[
        _position('a', 0.0, 0.0, 0.0, KeyframeEasing.easeOut.id),
        _position('b', 1.0, 100.0, 0.0),
      ];
      final eased = AnimationInterpolator.positionAt(track, 0.5)!;
      expect(eased.x, greaterThan(50.0));
    });

    test('hold easing keeps the earlier value until the next keyframe', () {
      final track = <Keyframe>[
        _position('a', 0.0, 0.0, 0.0, KeyframeEasing.hold.id),
        _position('b', 1.0, 100.0, 0.0),
      ];
      expect(AnimationInterpolator.positionAt(track, 0.5)!.x, closeTo(0.0, 1e-9));
      expect(AnimationInterpolator.positionAt(track, 0.999)!.x, closeTo(0.0, 1e-9));
      expect(AnimationInterpolator.positionAt(track, 1.0)!.x, closeTo(100.0, 1e-9));
    });

    test('parses and caches custom cubic-Bezier easings', () {
      final spec = EasingSpec.parse('cubic(0.42, 0, 1, 1)');
      expect(spec.isCustomBezier, isTrue);
      expect(spec.transform(0.0), closeTo(0.0, 1e-9));
      expect(spec.transform(1.0), closeTo(1.0, 1e-9));
      expect(spec.transform(0.5), lessThan(0.5)); // easeIn shape
      expect(identical(EasingSpec.parse('cubic(0.42, 0, 1, 1)'), spec), isTrue);
      expect(EasingSpec.parse('cubic(bad)').isCustomBezier, isFalse);
    });

    test('TrackCursor follows forward playback with an O(1) fast path', () {
      final track = <Keyframe>[
        _position('a', 0.0, 0.0, 0.0),
        _position('b', 1.0, 100.0, 0.0),
        _position('c', 2.0, 0.0, 0.0),
      ];
      final cursor = TrackCursor(track);
      expect((cursor.sampleAt(0.5) as Position).x, closeTo(50.0, 1e-9));
      expect(cursor.segmentIndex, 0);
      expect((cursor.sampleAt(1.5) as Position).x, closeTo(50.0, 1e-9));
      expect(cursor.segmentIndex, 1);
      expect((cursor.sampleAt(0.25) as Position).x, closeTo(25.0, 1e-9));
      expect(cursor.segmentIndex, 0);
    });
  });

  group('TransformMatrixEngine', () {
    const engine = TransformMatrixEngine();

    test('composes T * R * S in the documented order', () {
      final matrix = engine.compose(const LayerTransform(
        position: Position(x: 50.0, y: 20.0),
        rotation: Rotation(degrees: 90.0),
        scale: Scale(x: 2.0, y: 1.0),
      ));
      final translation = matrix.getTranslation();
      expect(translation.x, closeTo(50.0, 1e-9));
      expect(translation.y, closeTo(20.0, 1e-9));
      expect(matrix.entry(0, 0), closeTo(0.0, 1e-9)); // cos90 * 2
      expect(matrix.entry(1, 0), closeTo(2.0, 1e-9)); // sin90 * 2
      expect(matrix.entry(0, 1), closeTo(-1.0, 1e-9)); // -sin90 * 1
      expect(matrix.entry(1, 1), closeTo(0.0, 1e-9)); // cos90 * 1
    });

    test('multiplyInto returns parent * child', () {
      final parent = engine.compose(const LayerTransform(
        position: Position(x: 100.0, y: 0.0),
      ));
      final child = engine.compose(const LayerTransform(
        position: Position(x: 50.0, y: 0.0),
      ));
      final out = engine.multiplyInto(Matrix4.identity(), parent, child);
      expect(out.getTranslation().x, closeTo(150.0, 1e-9));
    });

    test('null-object parenting applies parent rotation to child position', () {
      const rig = Layer(
        id: 'rig',
        name: 'Rig',
        type: LayerType.nullObject,
        transform: LayerTransform(
          position: Position(x: 100.0, y: 0.0),
          rotation: Rotation(degrees: 90.0),
        ),
      );
      const child = Layer(
        id: 'child',
        name: 'Child',
        type: LayerType.video,
        transform: LayerTransform(position: Position(x: 50.0, y: 0.0)),
      );
      final world = engine.resolveWorld(
        child,
        localTransformOf: (layer) => layer.transform,
        parentOf: (layer) => layer.id == 'child' ? rig : null,
      );
      final translation = world.getTranslation();
      expect(translation.x, closeTo(100.0, 1e-9));
      expect(translation.y, closeTo(50.0, 1e-9));
    });
  });

  group('AdjustmentResolver', () {
    test('an adjustment layer affects only layers below it', () {
      final resolver = AdjustmentResolver()
        ..beginFrame()
        ..register(layerId: 'adj', stackIndex: 1);

      resolver.setEffect(
        'adj',
        const AdjustmentEffect(opacityMultiplier: 0.5, blurSigma: 4.0),
      );

      final below = resolver.aggregateFor(0);
      expect(below.opacityMultiplier, closeTo(0.5, 1e-9));
      expect(below.blurSigma, closeTo(4.0, 1e-9));

      final above = resolver.aggregateFor(1);
      expect(above.isNeutral, isTrue);
    });
  });

  group('MotionBlurProcessor', () {
    test('slow motion produces no blur', () {
      final estimator = MotionVelocityEstimator();
      const dt = 1.0 / 30.0;
      estimator.update(dt: dt, x: 0.0, y: 0.0, rotationDegrees: 0.0, scale: 1.0);
      estimator.update(dt: dt, x: 1.0, y: 0.0, rotationDegrees: 0.0, scale: 1.0);

      final plan = MotionBlurPlan();
      const processor = MotionBlurProcessor();
      processor.process(estimator: estimator, plan: plan, dt: dt);
      expect(plan.isActive, isFalse);
      expect(plan.sampleWeight, 1.0);
    });

    test('high velocity produces capped trailing samples', () {
      final estimator = MotionVelocityEstimator();
      const dt = 1.0 / 30.0;
      estimator.update(dt: dt, x: 0.0, y: 0.0, rotationDegrees: 0.0, scale: 1.0);
      estimator.update(dt: dt, x: 200.0, y: 0.0, rotationDegrees: 0.0, scale: 1.0);

      final plan = MotionBlurPlan();
      const processor = MotionBlurProcessor(); // low tier: max 3 samples
      processor.process(estimator: estimator, plan: plan, dt: dt);

      expect(plan.isActive, isTrue);
      expect(plan.sampleCount, greaterThanOrEqualTo(2));
      expect(plan.sampleCount, lessThanOrEqualTo(3));
      expect(plan.dxAt(0), lessThan(0.0)); // oldest sample trails behind
      expect(plan.dxAt(plan.sampleCount - 1), closeTo(0.0, 1e-6));
      expect(plan.blurSigma, greaterThan(0.0));
    });
  });

  group('AnimationPlaybackController', () {
    test('frame cache resolves keyframed transforms through the matrix engine',
        () {
      final controller = AnimationPlaybackController(frameRate: 30);
      final layer = controller.addLayerOfType(
        LayerType.video,
        startTime: 0.0,
        duration: 2.0,
      );
      controller.addKeyframe(layer.id, _position('k0', 0.0, 0.0, 0.0));
      controller.addKeyframe(layer.id, _position('k1', 2.0, 400.0, 0.0));

      controller.seek(1.0);
      controller.refresh();

      final state = controller.frameStateOf(layer.id);
      expect(state, isNotNull);
      expect(state!.worldTransform.position.x, closeTo(200.0, 1e-6));
      expect(state.worldMatrix.getTranslation().x, closeTo(200.0, 1e-6));
      controller.dispose();
    });

    test('adjustment layers modulate effective opacity', () {
      final controller = AnimationPlaybackController(frameRate: 30);
      final video = controller.addLayerOfType(
        LayerType.video,
        startTime: 0.0,
        duration: 2.0,
      );
      final adjustment = controller.addLayerOfType(
        LayerType.adjustmentLayer,
        startTime: 0.0,
        duration: 2.0,
      );
      controller.updateLayerOpacity(video.id, 0.8);
      controller.setAdjustmentEffect(
        adjustment.id,
        const AdjustmentEffect(opacityMultiplier: 0.5),
      );
      controller.seek(0.5);
      controller.refresh();

      expect(controller.effectiveOpacityOf(video), closeTo(0.4, 1e-6));
      expect(
        controller.effectsOf(video).opacityMultiplier,
        closeTo(0.5, 1e-6),
      );
      controller.dispose();
    });

    test('custom cubic easing survives insertion and drives the cache', () {
      final controller = AnimationPlaybackController(frameRate: 30);
      final layer = controller.addLayerOfType(
        LayerType.shape,
        startTime: 0.0,
        duration: 2.0,
      );
      controller.addKeyframe(
        layer.id,
        const Keyframe(
          id: 'k0',
          propertyName: KeyframeProperty.position,
          time: 0.0,
          value: Position(x: 0.0, y: 0.0),
          easingCurve: 'cubic(0.42, 0, 1, 1)',
        ),
      );
      controller.addKeyframe(layer.id, _position('k1', 2.0, 100.0, 0.0));

      controller.seek(1.0);
      controller.refresh();
      final x = controller.frameStateOf(layer.id)!.worldTransform.position.x;
      expect(x, greaterThan(0.0));
      expect(x, lessThan(50.0)); // easeIn shape is slower than linear early
      controller.dispose();
    });

    test('playback controls report state without a vsync', () {
      final controller = AnimationPlaybackController(frameRate: 30);
      expect(controller.canPlay, isFalse);
      expect(controller.play(), isFalse); // empty project + no ticker
      controller.addLayerOfType(LayerType.video, startTime: 0.0, duration: 1.0);
      controller.playbackSpeed = 4.0;
      expect(controller.playbackSpeed, closeTo(4.0, 1e-9));
      controller.playbackSpeed = 100.0;
      expect(controller.playbackSpeed, closeTo(8.0, 1e-9)); // clamped
      expect(controller.playbackProgress, closeTo(0.0, 1e-9));
      controller.dispose();
    });
  });
}
