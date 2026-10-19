// =============================================================================
// MOpus Studio - lib/main.dart
// -----------------------------------------------------------------------------
// Demo shell: PreviewCanvas on top, multi-track TimelineView below, wired to a
// single AnimationPlaybackController (Module 2 playback + frame cache). Replace
// this shell when the real editor home (project browser, export, ...) lands.
// =============================================================================

import 'package:flutter/material.dart';

import 'controllers/animation_controller_extension.dart';
import 'models/keyframe_model.dart';
import 'models/layer_model.dart';
import 'theme/mopus_theme.dart';
import 'views/preview_canvas.dart';
import 'views/timeline_view.dart';

void main() {
  runApp(const MopusStudioApp());
}

class MopusStudioApp extends StatelessWidget {
  const MopusStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MOpus Studio',
      debugShowCheckedModeBanner: false,
      theme: buildMopusTheme(),
      home: const EditorHomePage(),
    );
  }
}

class EditorHomePage extends StatefulWidget {
  const EditorHomePage({super.key});

  @override
  State<EditorHomePage> createState() => _EditorHomePageState();
}

class _EditorHomePageState extends State<EditorHomePage>
    with SingleTickerProviderStateMixin {
  late final AnimationPlaybackController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationPlaybackController(frameRate: 30, vsync: this);
    _seedDemoProject();
    _controller.loop = true; // demo: keep the rig moving for the blur pass
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// A small rig demonstrating parenting + keyframes + every layer type.
  void _seedDemoProject() {
    final controller = _controller;

    final rig = controller.addLayerOfType(
      LayerType.nullObject,
      startTime: 0,
      duration: 12,
    );
    controller.renameLayer(rig.id, 'Rig Root');

    final video = controller.addLayerOfType(
      LayerType.video,
      startTime: 0,
      duration: 8,
    );
    controller.setLayerParent(video.id, rig.id);

    final title = controller.addLayerOfType(
      LayerType.text,
      startTime: 1,
      duration: 4,
    );
    controller.renameLayer(title.id, 'MOpus Studio');
    controller.addKeyframe(
      title.id,
      const Keyframe(
        id: 'kf_demo_title_in',
        propertyName: KeyframeProperty.position,
        time: 1.0,
        value: Position(x: 0, y: 240),
      ),
    );
    controller.addKeyframe(
      title.id,
      Keyframe.eased(
        id: 'kf_demo_title_out',
        propertyName: KeyframeProperty.position,
        time: 2.0,
        value: const Position(x: 0, y: -160),
        easing: KeyframeEasing.easeOut,
      ),
    );

    controller.addLayerOfType(LayerType.audio, startTime: 0, duration: 10);
    controller.addLayerOfType(LayerType.shape, startTime: 8.5, duration: 3);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MopusColors.jetBlack,
      appBar: AppBar(
        title: const Text('MOPUS STUDIO'),
        actions: <Widget>[
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: 'Play / Pause',
                  icon: Icon(
                    _controller.isPlaying ? Icons.pause : Icons.play_arrow,
                  ),
                  color: MopusColors.electricOrange,
                  onPressed: _controller.togglePlayback,
                ),
                IconButton(
                  tooltip: 'Stop',
                  icon: const Icon(Icons.stop),
                  onPressed: _controller.stop,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                'MODULE 2 · ENGINE',
                style: MopusText.caption.copyWith(
                  color: MopusColors.electricOrange,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(flex: 5, child: PreviewCanvas(controller: _controller)),
          const Divider(height: 1, thickness: 1, color: MopusColors.hairline),
          Expanded(flex: 6, child: TimelineView(controller: _controller)),
        ],
      ),
    );
  }
}
