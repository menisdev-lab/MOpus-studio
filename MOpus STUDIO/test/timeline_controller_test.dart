// =============================================================================
// MOpus Studio - test/timeline_controller_test.dart
// -----------------------------------------------------------------------------
// Regression net for the Module 1 domain layer (no widgets pumped): layer
// lifecycle, timing shifts, Null Object parenting, keyframe evaluation.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:mopus_studio/controllers/timeline_controller.dart';
import 'package:mopus_studio/models/keyframe_model.dart';
import 'package:mopus_studio/models/layer_model.dart';

void main() {
  group('layers', () {
    test('add, shift and remove', () {
      final controller = TimelineController();
      final layer = controller.addLayerOfType(LayerType.video, duration: 4);

      expect(controller.layerCount, 1);
      expect(layer.startTime, 0.0);
      expect(layer.endTime, 4.0);
      expect(controller.projectDuration, 4.0);
      expect(layer.containsTime(4.0), isFalse); // half-open interval

      expect(controller.shiftLayerTiming(layer.id, delta: 2.0), isTrue);
      expect(controller.layerById(layer.id)!.startTime, 2.0);
      expect(controller.shiftLayerTiming(layer.id, delta: -5.0), isTrue);
      expect(controller.layerById(layer.id)!.startTime, 0.0); // clamped

      expect(controller.removeLayer(layer.id), isTrue);
      expect(controller.isEmpty, isTrue);
    });

    test('locked layers reject edits', () {
      final controller = TimelineController();
      final layer = controller.addLayerOfType(LayerType.text);
      controller.setLayerLocked(layer.id, true);

      expect(controller.shiftLayerTiming(layer.id, delta: 1.0), isFalse);
      expect(
        controller.updateLayerTransform(layer.id, const LayerTransform()),
        isFalse,
      );
    });
  });

  group('null object parenting', () {
    test('child inherits parent transform', () {
      final controller = TimelineController();
      final parent = controller.addLayerOfType(LayerType.nullObject);
      final child = controller.addLayerOfType(LayerType.video);

      expect(controller.setLayerParent(child.id, parent.id), isTrue);
      expect(controller.layerById(child.id)!.parentId, parent.id);

      controller.updateLayerTransform(
        parent.id,
        const LayerTransform(position: Position(x: 100, y: 50)),
      );

      final parentLayer = controller.layerById(parent.id)!;
      final childLayer = controller.layerById(child.id)!;
      final world = controller.resolveWorldTransform(childLayer);

      expect(world.position, const Position(x: 100, y: 50));
      // Sanity: the parent itself is unchanged by the composition.
      expect(controller.resolveWorldTransform(parentLayer).position,
          const Position(x: 100, y: 50));
    });

    test('rejects non null-object parents, self and cycles', () {
      final controller = TimelineController();
      final a = controller.addLayerOfType(LayerType.nullObject);
      final b = controller.addLayerOfType(LayerType.nullObject);
      final video = controller.addLayerOfType(LayerType.video);

      expect(controller.setLayerParent(video.id, video.id), isFalse);
      expect(controller.setLayerParent(video.id, b.id), isTrue);
      // a -> b would close the cycle b -> video <- a? a->b and b has no parent.
      expect(controller.setLayerParent(a.id, b.id), isTrue);
      // Now b cannot be parented to a (cycle: a -> b -> a).
      expect(controller.setLayerParent(b.id, a.id), isFalse);
      // A video layer can never be a parent.
      expect(controller.setLayerParent(a.id, video.id), isFalse);
    });

    test('removing a parent detaches children', () {
      final controller = TimelineController();
      final parent = controller.addLayerOfType(LayerType.nullObject);
      final child = controller.addLayerOfType(LayerType.shape);
      controller.setLayerParent(child.id, parent.id);

      controller.removeLayer(parent.id);
      expect(controller.layerById(child.id)!.parentId, isNull);
    });
  });

  group('keyframes', () {
    test('linear interpolation between two position keys', () {
      final controller = TimelineController();
      final layer = controller.addLayerOfType(LayerType.text, duration: 10);

      controller.addKeyframe(
        layer.id,
        const Keyframe(
          id: 'kf_a',
          propertyName: KeyframeProperty.position,
          time: 0.0,
          value: Position(x: 0, y: 0),
        ),
      );
      controller.addKeyframe(
        layer.id,
        const Keyframe(
          id: 'kf_b',
          propertyName: KeyframeProperty.position,
          time: 2.0,
          value: Position(x: 200, y: 100),
        ),
      );

      final mid = controller.evaluateProperty(
        layer.id,
        KeyframeProperty.position,
        1.0,
      );
      expect(mid, isA<Position>());
      expect((mid as Position).x, closeTo(100.0, 1e-6));
      expect(mid.y, closeTo(50.0, 1e-6));

      // Before the first key -> first value; after the last -> last value.
      expect(
        (controller.evaluateProperty(layer.id, KeyframeProperty.position, -1.0)
                as Position)
            .x,
        0.0,
      );
      expect(
        (controller.evaluateProperty(layer.id, KeyframeProperty.position, 9.0)
                as Position)
            .x,
        200.0,
      );
    });

    test('auto-key writes to keyframes once a track exists', () {
      final controller = TimelineController();
      final layer = controller.addLayerOfType(LayerType.video, duration: 10);

      controller.seek(1.0);
      controller.addKeyframesAtPlayhead(layer.id);
      expect(controller.keyframesFor(layer.id, KeyframeProperty.position).length, 1);

      controller.seek(3.0);
      controller.updateLayerTransform(
        layer.id,
        const LayerTransform(position: Position(x: 60, y: 0)),
      );

      final track = controller.keyframesFor(layer.id, KeyframeProperty.position);
      expect(track.length, 2);
      expect(track.last.time, closeTo(3.0, 1e-9));
      expect(track.last.value, const Position(x: 60, y: 0));
    });

    test('keyframes are removed with their layer', () {
      final controller = TimelineController();
      final layer = controller.addLayerOfType(LayerType.video);
      controller.addKeyframesAtPlayhead(layer.id);
      expect(controller.hasKeyframes(layer.id), isTrue);

      controller.removeLayer(layer.id);
      expect(controller.hasKeyframes(layer.id), isFalse);
    });
  });

  group('playhead + formatting', () {
    test('seek clamps and steps frames', () {
      final controller = TimelineController(frameRate: 30);
      controller.addLayerOfType(LayerType.video, duration: 5);

      controller.seek(-2.0);
      expect(controller.playhead, 0.0);

      controller.seek(100.0);
      expect(controller.playhead, 5.0);

      controller.seek(0.0);
      controller.stepFrames(15);
      expect(controller.playhead, closeTo(0.5, 1e-9));
      expect(controller.playheadFrame, 15);
    });

    test('timecode format', () {
      final controller = TimelineController(frameRate: 30);
      expect(controller.formatTimecode(0.0), '00:00:00:00');
      expect(controller.formatTimecode(61.5), '00:01:01:15');
      expect(controller.formatRulerLabel(65.0), '1:05');
    });
  });

  group('snapping', () {
    test('nearest snap point respects tolerance', () {
      final controller = TimelineController();
      controller.addLayerOfType(LayerType.video, startTime: 2.0, duration: 3.0);

      expect(controller.nearestSnapPoint(1.95, 0.1), 2.0);
      expect(controller.nearestSnapPoint(5.05, 0.1), 5.0);
      expect(controller.nearestSnapPoint(3.5, 0.1), isNull);
    });
  });
}
