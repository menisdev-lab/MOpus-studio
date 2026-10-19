// =============================================================================
// MOpus Studio - lib/engine/effects_library.dart
// -----------------------------------------------------------------------------
// Effects pipeline (Module 3).
//
// Pure, backend-agnostic effect definitions. Every effect knows how to express
// itself as one FFmpeg filter string, so the export pipeline builds filter
// chains without a big switch in the renderer, and the editor UI can enumerate
// the same list for its adjustment panel.
//
// Adjustment-layer pass-through (After Effects semantics): [EffectsLibrary]
// converts a Module 2 [AdjustmentAggregate] into the chain applied to every
// visual track *below* the adjustment layer. Offline export therefore matches
// the live preview aggregation exactly - the preview painter consumes the same
// aggregate object.
//
// Numeric ranges mirror the FFmpeg filters so nothing is silently clamped at
// render time. All numbers are formatted through [ffmpegNumber], which never
// emits scientific notation (FFmpeg's expression parser rejects `1e-5`).
// =============================================================================

import 'package:flutter/foundation.dart';

import 'transform_matrix_engine.dart';

// -----------------------------------------------------------------------------
// Formatting helpers
// -----------------------------------------------------------------------------

/// Formats [value] for FFmpeg: fixed notation, at most 6 decimals, no trailing
/// zeros. Non-finite inputs degrade to `0` so a corrupted project cannot emit
/// a broken filter graph.
String ffmpegNumber(double value) {
  if (!value.isFinite) return '0';
  var text = value.toStringAsFixed(6);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  }
  if (text.isEmpty || text == '-') return '0';
  return text;
}

double _clampDouble(double value, double min, double max) =>
    value.clamp(min, max).toDouble();

// -----------------------------------------------------------------------------
// Effect model
// -----------------------------------------------------------------------------

/// Base class of every effect the offline renderer understands.
///
/// Sealed on purpose: adding a new effect forces every `switch` (renderer,
/// UI, persistence) to handle it at compile time.
sealed class VideoEffect {
  const VideoEffect();

  /// Human label used by the editor's effect browser.
  String get label;

  /// One FFmpeg filter string without link labels, e.g.
  /// `eq=brightness=-0.15` or `hue=h=30:s=1.2`. A filter may itself be a chain
  /// (`a=1,b=2`) - [EffectsLibrary.chain] joins effects with commas anyway.
  String toFfmpegFilter();

  /// `true` when the effect is a no-op and should be dropped from the chain.
  bool get isNeutral;

  Map<String, dynamic> toJson();
}

/// Brightness / contrast / saturation in a single `eq` pass (cheapest grade).
@immutable
class ToneEffect extends VideoEffect {
  const ToneEffect({
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
  });

  /// -1.0 (black) .. 1.0 (white), 0.0 = untouched.
  final double brightness;

  /// 1.0 = untouched; values above stretch around mid-grey.
  final double contrast;

  /// 1.0 = untouched, 0.0 = greyscale.
  final double saturation;

  @override
  String get label => 'Tone';

  @override
  bool get isNeutral =>
      brightness == 0.0 && contrast == 1.0 && saturation == 1.0;

  @override
  String toFfmpegFilter() =>
      'eq=brightness=${ffmpegNumber(_clampDouble(brightness, -1.0, 1.0))}'
      ':contrast=${ffmpegNumber(_clampDouble(contrast, 0.0, 4.0))}'
      ':saturation=${ffmpegNumber(_clampDouble(saturation, 0.0, 3.0))}';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': 'tone',
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
      };

  ToneEffect copyWith({double? brightness, double? contrast, double? saturation}) =>
      ToneEffect(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
      );

  @override
  bool operator ==(Object other) =>
      other is ToneEffect &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation;

  @override
  int get hashCode => Object.hash(brightness, contrast, saturation);

  @override
  String toString() => 'ToneEffect($brightness, $contrast, $saturation)';
}

/// Hue rotation + HSL saturation/lightness (`hue`, plus `eq` for lightness).
@immutable
class HslEffect extends VideoEffect {
  const HslEffect({
    this.hueDegrees = 0.0,
    this.saturation = 1.0,
    this.lightness = 0.0,
  });

  /// 0 = untouched; the filter accepts any value (wraps around 360).
  final double hueDegrees;

  /// 1.0 = untouched, 0.0 = greyscale.
  final double saturation;

  /// -1.0 .. 1.0 additive lightness, applied through `eq=brightness`.
  final double lightness;

  @override
  String get label => 'Hue / Saturation';

  @override
  bool get isNeutral =>
      hueDegrees == 0.0 && saturation == 1.0 && lightness == 0.0;

  @override
  String toFfmpegFilter() {
    final hue = 'hue=h=${ffmpegNumber(hueDegrees)}'
        ':s=${ffmpegNumber(_clampDouble(saturation, 0.0, 3.0))}';
    if (lightness == 0.0) return hue;
    return '$hue,eq=brightness=${ffmpegNumber(_clampDouble(lightness, -1.0, 1.0))}';
  }

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': 'hsl',
        'hueDegrees': hueDegrees,
        'saturation': saturation,
        'lightness': lightness,
      };

  @override
  bool operator ==(Object other) =>
      other is HslEffect &&
      other.hueDegrees == hueDegrees &&
      other.saturation == saturation &&
      other.lightness == lightness;

  @override
  int get hashCode => Object.hash(hueDegrees, saturation, lightness);

  @override
  String toString() => 'HslEffect($hueDegrees, $saturation, $lightness)';
}

/// Warm/cool grading via `colorbalance` (shadow + highlight split).
///
/// Warm values push orange into the highlights and blue into the shadows
/// (the classic teal/orange look) and stay a single cheap pass - important on
/// 2GB devices where per-pixel filters are the first thing to drop frames.
@immutable
class ColorTintEffect extends VideoEffect {
  const ColorTintEffect({this.temperature = 0.0, this.tint = 0.0});

  /// -1.0 (cool) .. 1.0 (warm).
  final double temperature;

  /// -1.0 (magenta) .. 1.0 (green).
  final double tint;

  @override
  String get label => 'Color Tint';

  @override
  bool get isNeutral => temperature == 0.0 && tint == 0.0;

  @override
  String toFfmpegFilter() {
    final warm = _clampDouble(temperature, -1.0, 1.0);
    final green = _clampDouble(tint, -1.0, 1.0);
    final rs = -warm * 0.15;
    final bs = warm * 0.15;
    final rh = warm * 0.35;
    final bh = -warm * 0.35;
    final rm = -green * 0.10;
    final gm = green * 0.20;
    final bm = -green * 0.10;
    return 'colorbalance'
        ':rs=${ffmpegNumber(rs)}:bs=${ffmpegNumber(bs)}'
        ':rm=${ffmpegNumber(rm)}:gm=${ffmpegNumber(gm)}:bm=${ffmpegNumber(bm)}'
        ':rh=${ffmpegNumber(rh)}:bh=${ffmpegNumber(bh)}';
  }

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': 'colorTint',
        'temperature': temperature,
        'tint': tint,
      };

  @override
  bool operator ==(Object other) =>
      other is ColorTintEffect &&
      other.temperature == temperature &&
      other.tint == tint;

  @override
  int get hashCode => Object.hash(temperature, tint);

  @override
  String toString() => 'ColorTintEffect($temperature, $tint)';
}

/// Gaussian blur (`gblur`). `steps=1` keeps a single intermediate buffer,
/// which is the difference between "blurs fine" and "OOM" on low-RAM phones.
@immutable
class GaussianBlurEffect extends VideoEffect {
  const GaussianBlurEffect({this.sigma = 0.0});

  /// 0 = off; 1..40 covers soft-skin through dreamy canvases.
  final double sigma;

  @override
  String get label => 'Gaussian Blur';

  @override
  bool get isNeutral => sigma <= 0.0;

  @override
  String toFfmpegFilter() =>
      'gblur=sigma=${ffmpegNumber(_clampDouble(sigma, 0.0, 60.0))}:steps=1';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': 'gaussianBlur',
        'sigma': sigma,
      };

  @override
  bool operator ==(Object other) =>
      other is GaussianBlurEffect && other.sigma == sigma;

  @override
  int get hashCode => sigma.hashCode;

  @override
  String toString() => 'GaussianBlurEffect($sigma)';
}

/// Motion blur overlay: temporal averaging of successive frames (`tmix`).
///
/// This is the offline counterpart of Module 2's [MotionBlurProcessor]: the
/// preview smears the matrix samples it already has, and the exporter averages
/// the same number of real frames instead of re-deriving velocities. Weights
/// default to [trailingWeights], which mirror the preview plan (newest sample
/// sharp, older samples trailing behind).
@immutable
class MotionBlurOverlayEffect extends VideoEffect {
  const MotionBlurOverlayEffect({this.frames = 3, this.weights});

  /// Number of frames averaged together (2..16).
  final int frames;

  /// Optional per-frame weights; must contain exactly [frames] values.
  final List<double>? weights;

  @override
  String get label => 'Motion Blur Overlay';

  @override
  bool get isNeutral => frames < 2;

  @override
  String toFfmpegFilter() {
    final count = frames < 2 ? 2 : (frames > 16 ? 16 : frames);
    final weights = this.weights;
    if (weights == null || weights.length != count) {
      return 'tmix=frames=$count';
    }
    final joined =
        weights.map((value) => ffmpegNumber(_clampDouble(value, 0.0, 1.0))).join(' ');
    return "tmix=frames=$count:weights='$joined'";
  }

  /// Builds normalised trailing-average weights: index 0 is the oldest sample
  /// (weakest), the last index is the sharp current frame.
  static List<double> trailingWeights(int count) {
    if (count < 2) return const <double>[1.0];
    final weights = List<double>.filled(count, 1.0);
    var total = 0.0;
    for (var i = 0; i < count; i++) {
      final weight = (i + 1) / count;
      weights[i] = weight;
      total += weight;
    }
    for (var i = 0; i < count; i++) {
      weights[i] = weights[i] / total;
    }
    return weights;
  }

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': 'motionBlurOverlay',
        'frames': frames,
        if (weights != null) 'weights': weights,
      };

  @override
  bool operator ==(Object other) =>
      other is MotionBlurOverlayEffect &&
      other.frames == frames &&
      (identical(other.weights, weights) ||
          (other.weights != null &&
              weights != null &&
              listEquals(other.weights, weights)));

  @override
  int get hashCode =>
      Object.hash(frames, weights == null ? null : Object.hashAll(weights!));

  @override
  String toString() => 'MotionBlurOverlayEffect($frames)';
}

/// Unsharp mask - crispness without a full convolution kernel.
@immutable
class SharpenEffect extends VideoEffect {
  const SharpenEffect({this.amount = 0.5});

  /// 0 = off; 0.3..1.5 is the sane mobile range (2.0 = harsh edges).
  final double amount;

  @override
  String get label => 'Sharpen';

  @override
  bool get isNeutral => amount <= 0.0;

  @override
  String toFfmpegFilter() =>
      'unsharp=5:5:${ffmpegNumber(_clampDouble(amount, 0.0, 2.0))}';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': 'sharpen',
        'amount': amount,
      };

  @override
  bool operator ==(Object other) =>
      other is SharpenEffect && other.amount == amount;

  @override
  int get hashCode => amount.hashCode;

  @override
  String toString() => 'SharpenEffect($amount)';
}

/// Lens vignette (`vignette`).
@immutable
class VignetteEffect extends VideoEffect {
  const VignetteEffect({this.angleRadians = 0.628});

  /// Angle of the outer ellipse; ~PI/5 is a subtle lens falloff.
  final double angleRadians;

  @override
  String get label => 'Vignette';

  @override
  bool get isNeutral => angleRadians <= 0.0;

  @override
  String toFfmpegFilter() =>
      'vignette=angle=${ffmpegNumber(_clampDouble(angleRadians, 0.0, 3.14))}';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': 'vignette',
        'angleRadians': angleRadians,
      };

  @override
  bool operator ==(Object other) =>
      other is VignetteEffect && other.angleRadians == angleRadians;

  @override
  int get hashCode => angleRadians.hashCode;

  @override
  String toString() => 'VignetteEffect($angleRadians)';
}

double _asDouble(Object? value, [double fallback = 0.0]) =>
    value is num ? value.toDouble() : fallback;

/// Rebuilds an effect from [toJson] output; returns `null` for unknown kinds
/// so projects written by a newer build degrade instead of crashing.
VideoEffect? decodeVideoEffect(Map<String, dynamic> json) {
  switch (json['kind']) {
    case 'tone':
      return ToneEffect(
        brightness: _asDouble(json['brightness']),
        contrast: _asDouble(json['contrast'], 1.0),
        saturation: _asDouble(json['saturation'], 1.0),
      );
    case 'hsl':
      return HslEffect(
        hueDegrees: _asDouble(json['hueDegrees']),
        saturation: _asDouble(json['saturation'], 1.0),
        lightness: _asDouble(json['lightness']),
      );
    case 'colorTint':
      return ColorTintEffect(
        temperature: _asDouble(json['temperature']),
        tint: _asDouble(json['tint']),
      );
    case 'gaussianBlur':
      return GaussianBlurEffect(sigma: _asDouble(json['sigma']));
    case 'motionBlurOverlay':
      final rawWeights = json['weights'];
      final weights = rawWeights is List
          ? rawWeights
              .whereType<num>()
              .map((value) => value.toDouble())
              .toList(growable: false)
          : null;
      final frames = json['frames'];
      return MotionBlurOverlayEffect(
        frames: frames is int ? frames : 3,
        weights: weights,
      );
    case 'sharpen':
      return SharpenEffect(amount: _asDouble(json['amount'], 0.5));
    case 'vignette':
      return VignetteEffect(angleRadians: _asDouble(json['angleRadians'], 0.628));
    default:
      return null;
  }
}

// -----------------------------------------------------------------------------
// Library facade
// -----------------------------------------------------------------------------

/// Static entry points used by the renderer, the preview painter and the
/// upcoming effects UI. All methods are pure - no state, no I/O.
abstract final class EffectsLibrary {
  /// Joins effect filters into one FFmpeg chain string (comma = sequential).
  /// Neutral effects and empty filters are dropped, so a project with no
  /// adjustments produces an empty string and zero extra graph nodes.
  static String chain(List<VideoEffect> effects) {
    if (effects.isEmpty) return '';
    final parts = <String>[];
    for (final effect in effects) {
      if (effect.isNeutral) continue;
      final filter = effect.toFfmpegFilter();
      if (filter.isEmpty) continue;
      parts.add(filter);
    }
    return parts.join(',');
  }

  /// Converts a resolved adjustment into ordered video effects.
  ///
  /// [AdjustmentEffect.opacityMultiplier] is intentionally not converted: the
  /// renderer multiplies it into the layer's alpha channel instead, so the
  /// preview and the export share the exact same opacity path.
  static List<VideoEffect> fromEffect(AdjustmentEffect effect) {
    if (effect.isNeutral) return const <VideoEffect>[];
    final effects = <VideoEffect>[];
    final tone = ToneEffect(
      brightness: effect.brightness,
      contrast: effect.contrast,
      saturation: effect.saturation,
    );
    if (!tone.isNeutral) effects.add(tone);
    if (effect.temperature != 0.0) {
      effects.add(ColorTintEffect(temperature: effect.temperature));
    }
    if (effect.blurSigma > 0.0) {
      effects.add(GaussianBlurEffect(sigma: effect.blurSigma));
    }
    return effects;
  }

  /// Adjustment-layer pass-through: the chain applied to every visual track
  /// below the adjustment layer.
  static List<VideoEffect> fromAggregate(AdjustmentAggregate aggregate) =>
      fromEffect(aggregate.toEffect());

  /// Convenience for the renderer: aggregate -> ready-to-append chain string.
  static String chainFromAggregate(AdjustmentAggregate aggregate) =>
      chain(fromAggregate(aggregate));

  /// The default bricks shown by the effect browser (UI staging).
  static List<VideoEffect> browserDefaults() => const <VideoEffect>[
        ToneEffect(),
        HslEffect(),
        ColorTintEffect(),
        GaussianBlurEffect(),
        MotionBlurOverlayEffect(frames: 3),
        SharpenEffect(),
        VignetteEffect(),
      ];
}
