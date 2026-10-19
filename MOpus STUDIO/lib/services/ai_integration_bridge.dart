// =============================================================================
// MOpus Studio - lib/services/ai_integration_bridge.dart
// -----------------------------------------------------------------------------
// AI Ready-Stage Architecture (Module 3).
//
// Offline first, AI later - and never the other way round:
//   * Nothing in this file performs network I/O. It defines *contracts* and a
//     registry; concrete providers (REST clients, on-device models, FFI) plug
//     in through [AiIntegrationBridge.register] and can be swapped without
//     touching a single line of editing or rendering code.
//   * Every capability has a safe default: when no provider is registered, the
//     app is offline, or the user has not opted in, the bridge returns a failed
//     [AiJobResult] instead of throwing - export and editing paths keep
//     working unchanged.
//   * API keys are never logged: [AiProviderConfig.toString] redacts them and
//     key material travels through [AiCredentialStore] (in-memory default; a
//     keystore-backed implementation drops in later).
//
// Staged capabilities:
//   * `autoCaptions`      - speech to timed caption segments.
//   * `backgroundRemoval` - alpha matte / cutout per frame.
//   * `voiceoverTts`      - text to speech tracks.
//   * `videoUpscale`      - 2x/4x super-resolution.
//
// [AiStagingConfig] keeps every AI code path dark until the user opts in, which
// is also what keeps the APK installable and battery-friendly on 2GB devices.
// =============================================================================

import 'package:flutter/foundation.dart';

import '../controllers/timeline_controller.dart';
import '../models/layer_model.dart';

// -----------------------------------------------------------------------------
// Capabilities
// -----------------------------------------------------------------------------

/// Capabilities the bridge can route. Extend this enum when a new AI feature is
/// staged; registering a provider for an unknown capability stays a no-op.
enum AiCapability {
  autoCaptions('Auto Captions'),
  backgroundRemoval('Background Removal'),
  voiceoverTts('Voiceover (TTS)'),
  videoUpscale('Video Upscaler');

  const AiCapability(this.label);

  /// Label for the settings / staging UI.
  final String label;

  /// Default transport hint. Overridable by the provider descriptor: cloud
  /// providers need `allowNetwork`, on-device models respect
  /// `allowOnDeviceModels` instead.
  bool get defaultRequiresNetwork => switch (this) {
        AiCapability.autoCaptions => true,
        AiCapability.voiceoverTts => true,
        AiCapability.backgroundRemoval => false,
        AiCapability.videoUpscale => false,
      };
}

// -----------------------------------------------------------------------------
// Staging configuration
// -----------------------------------------------------------------------------

/// Feature switches for the staged AI layer.
///
/// The default is deliberately absolute: no network, no capabilities enabled.
/// A user (or a future settings screen) opts in per capability, so a normal
/// editing session can never accidentally hit a paid API.
@immutable
class AiStagingConfig {
  const AiStagingConfig({
    this.allowNetwork = false,
    this.allowOnDeviceModels = true,
    this.enabledCapabilities = const <AiCapability>{},
    this.requestTimeout = const Duration(seconds: 120),
    this.telemetry = false,
  });

  /// The app's default: nothing leaves the device.
  static const AiStagingConfig offlineDefault = AiStagingConfig();

  /// Master switch for remote providers (cloud captions, cloud TTS, ...).
  final bool allowNetwork;

  /// On-device models (cutout, upscale) are local compute, not data movement,
  /// so they only need the user's explicit capability opt-in.
  final bool allowOnDeviceModels;

  /// Capabilities the user opted into. Empty = everything stays dark even when
  /// a provider is registered (safe rollout / no surprise bills).
  final Set<AiCapability> enabledCapabilities;

  /// Per-request timeout handed to providers.
  final Duration requestTimeout;

  /// Anonymous quality telemetry. Off by default; media never leaves the
  /// device in any configuration.
  final bool telemetry;

  /// `true` when the user opted into [capability].
  bool allows(AiCapability capability) =>
      enabledCapabilities.contains(capability);

  /// `true` when the transport for [capability] is permitted.
  bool transportAllowed(AiCapability capability) => capability
          .defaultRequiresNetwork
      ? allowNetwork
      : allowOnDeviceModels;

  AiStagingConfig copyWith({
    bool? allowNetwork,
    bool? allowOnDeviceModels,
    Set<AiCapability>? enabledCapabilities,
    Duration? requestTimeout,
    bool? telemetry,
  }) =>
      AiStagingConfig(
        allowNetwork: allowNetwork ?? this.allowNetwork,
        allowOnDeviceModels: allowOnDeviceModels ?? this.allowOnDeviceModels,
        enabledCapabilities: enabledCapabilities ?? this.enabledCapabilities,
        requestTimeout: requestTimeout ?? this.requestTimeout,
        telemetry: telemetry ?? this.telemetry,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'allowNetwork': allowNetwork,
        'allowOnDeviceModels': allowOnDeviceModels,
        'enabledCapabilities':
            enabledCapabilities.map((capability) => capability.name).toList(),
        'telemetry': telemetry,
      };

  @override
  String toString() => 'AiStagingConfig(network: $allowNetwork, '
      'onDevice: $allowOnDeviceModels, '
      'enabled: ${enabledCapabilities.map((c) => c.name).join(',')})';
}

// -----------------------------------------------------------------------------
// Credentials
// -----------------------------------------------------------------------------

/// Minimal key/value store for provider credentials.
///
/// The default implementation is in-memory - keys disappear on restart, which
/// is the right behaviour for a staging build. A later module backs this with
/// the platform keystore / keychain without changing a single call site.
abstract interface class AiCredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> clear();
}

/// In-memory [AiCredentialStore]. Never logs, never persists.
class InMemoryAiCredentialStore implements AiCredentialStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> clear() async {
    _values.clear();
  }
}

// -----------------------------------------------------------------------------
// Provider configuration
// -----------------------------------------------------------------------------

/// Connection description for one provider instance.
@immutable
class AiProviderConfig {
  const AiProviderConfig({
    required this.name,
    required this.capability,
    this.endpoint = '',
    this.model = '',
    this.apiKey = '',
    this.timeout = const Duration(seconds: 120),
    this.enabled = true,
  });

  /// Identifier shown in settings ("mopus-cloud", "openai", "local-ncnn").
  final String name;

  final AiCapability capability;

  /// Base URL for remote providers; empty for on-device ones.
  final String endpoint;

  /// Model id / variant (`whisper-1`, `upscale-x4`, ...).
  final String model;

  /// Key material. Populated from [AiCredentialStore]; never serialised.
  final String apiKey;

  final Duration timeout;
  final bool enabled;

  bool get hasCredentials => apiKey.isNotEmpty;

  /// Copy with a key loaded from the credential store.
  AiProviderConfig withApiKey(String key) => AiProviderConfig(
        name: name,
        capability: capability,
        endpoint: endpoint,
        model: model,
        apiKey: key,
        timeout: timeout,
        enabled: enabled,
      );

  /// Never print the key - logs and crash reports are public artefacts.
  @override
  String toString() => 'AiProviderConfig($name, ${capability.name}, '
      'endpoint=${endpoint.isEmpty ? '<none>' : endpoint}, '
      'model=${model.isEmpty ? '<default>' : model}, '
      'key=${hasCredentials ? '<redacted>' : '<missing>'})';
}

// -----------------------------------------------------------------------------
// Jobs
// -----------------------------------------------------------------------------

/// One AI request. [inputPath] is always a local file; uploads are the
/// provider's business, never the bridge's.
@immutable
class AiJobRequest {
  const AiJobRequest({
    required this.capability,
    required this.inputPath,
    this.outputPath,
    this.parameters = const <String, Object?>{},
    this.requestId = '',
  });

  final AiCapability capability;

  /// Source media (video/audio/image) on local storage.
  final String inputPath;

  /// Requested destination; providers may return their own temp path instead.
  final String? outputPath;

  /// Provider-specific options (language, voice id, upscale factor, ...).
  final Map<String, Object?> parameters;

  /// Correlation id; generated by the bridge when empty.
  final String requestId;

  String describe() => '${capability.name}(${inputPath.split(RegExp(r'[/\\]')).last})';

  @override
  String toString() => 'AiJobRequest(${describe()})';
}

/// Result of one AI request. Failures are values, not exceptions, so callers
/// like the export engine can treat AI as strictly optional.
@immutable
class AiJobResult {
  const AiJobResult({
    required this.requestId,
    required this.capability,
    required this.succeeded,
    this.outputPath,
    this.payload = const <String, Object?>{},
    this.errorMessage,
    this.duration = Duration.zero,
  });

  /// Convenience constructor for the "not available right now" path used by
  /// every offline run.
  factory AiJobResult.unavailable(
    AiJobRequest request,
    String reason,
  ) =>
      AiJobResult(
        requestId: request.requestId,
        capability: request.capability,
        succeeded: false,
        errorMessage: reason,
      );

  final String requestId;
  final AiCapability capability;
  final bool succeeded;

  /// Produced file (matte, audio track, upscaled clip), when any.
  final String? outputPath;

  /// Structured extras (caption segments, frame counts, model info).
  final Map<String, Object?> payload;

  /// `null` when [succeeded].
  final String? errorMessage;

  final Duration duration;

  bool get isFailure => !succeeded;

  String describe() => succeeded
      ? 'OK ${capability.name} in ${duration.inMilliseconds}ms'
      : 'FAILED ${capability.name}: ${errorMessage ?? 'unknown'}';

  @override
  String toString() => 'AiJobResult(${describe()})';
}

// -----------------------------------------------------------------------------
// Errors
// -----------------------------------------------------------------------------

/// Thrown only by provider implementations; the bridge itself returns values.
class AiBridgeException implements Exception {
  const AiBridgeException(this.message, {this.capability, this.cause});

  final String message;
  final AiCapability? capability;
  final Object? cause;

  @override
  String toString() => 'AiBridgeException($message'
      '${capability == null ? '' : ', ${capability!.name}'}'
      '${cause == null ? '' : ', cause: $cause'})';
}

/// Legacy-compatible alias: thrown when a caller insists on a capability that
/// is not staged (instead of accepting the [AiJobResult] failure value).
class AiUnavailableException extends AiBridgeException {
  const AiUnavailableException(AiCapability capability, String reason)
      : super(reason, capability: capability);
}

// -----------------------------------------------------------------------------
// Typed payloads
// -----------------------------------------------------------------------------

/// One caption line produced by [AiAutoCaptionService].
@immutable
class AiCaptionSegment {
  const AiCaptionSegment({
    required this.start,
    required this.end,
    required this.text,
    this.speaker,
    this.confidence,
  });

  /// Seconds on the source timeline.
  final double start;
  final double end;

  final String text;
  final String? speaker;

  /// Provider confidence 0..1, when reported.
  final double? confidence;

  double get duration => end - start;

  /// Rejects segments that would corrupt the timeline (bad or inverted times,
  /// empty text) - providers are untrusted input.
  bool get isValid =>
      start.isFinite &&
      end.isFinite &&
      end > start &&
      text.trim().isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'start': start,
        'end': end,
        'text': text,
        if (speaker != null) 'speaker': speaker,
        if (confidence != null) 'confidence': confidence,
      };

  static AiCaptionSegment? fromJson(Map<String, dynamic> json) {
    final start = json['start'];
    final end = json['end'];
    final text = json['text'];
    if (start is! num || end is! num || text is! String) return null;
    final segment = AiCaptionSegment(
      start: start.toDouble(),
      end: end.toDouble(),
      text: text,
      speaker: json['speaker'] is String ? json['speaker'] as String : null,
      confidence:
          json['confidence'] is num ? (json['confidence'] as num).toDouble() : null,
    );
    return segment.isValid ? segment : null;
  }

  @override
  String toString() => 'AiCaptionSegment(${start.toStringAsFixed(2)}'
      '-${end.toStringAsFixed(2)}: $text)';
}

/// Alpha matte produced by [AiBackgroundRemovalService].
@immutable
class AiAlphaMatte {
  const AiAlphaMatte({
    required this.mattePath,
    required this.width,
    required this.height,
    this.frameRate = 0.0,
    this.alphaInverted = false,
  });

  /// Matte media: white = foreground. A single image when [frameRate] is 0,
  /// otherwise a video/sequence aligned frame-by-frame with the source.
  final String mattePath;
  final int width;
  final int height;
  final double frameRate;

  /// Some runtimes emit black-on-white mattes; the flag saves an invert pass.
  final bool alphaInverted;

  bool get isSequence => frameRate > 0.0;

  @override
  String toString() => 'AiAlphaMatte($mattePath, ${width}x$height'
      '${isSequence ? ', ${frameRate}fps' : ''})';
}

/// Upscale factors exposed to the UI.
enum AiUpscaleFactor {
  x2(2),
  x4(4);

  const AiUpscaleFactor(this.factor);

  final int factor;

  /// Target size for a source size, rounded up to even dimensions (H.264).
  (int, int) targetSize(int width, int height) =>
      (_even(width * factor), _even(height * factor));

  static int _even(int value) => value.isEven ? value : value + 1;

  @override
  String toString() => '${factor}x';
}

// -----------------------------------------------------------------------------
// Service contracts
// -----------------------------------------------------------------------------

/// Base contract every AI provider implements.
abstract interface class AiService {
  /// Capability this provider fulfils.
  AiCapability get capability;

  /// Configuration (name, endpoint, model, key presence).
  AiProviderConfig get config;

  /// `true` when the provider has everything it needs (key, model, permissions).
  bool get isConfigured;

  /// Human-readable status for the settings screen.
  String get status;

  /// Executes one request.
  ///
  /// Expected failures return a failed [AiJobResult]; implementations must not
  /// throw for network/timeout/auth problems so the app stays usable offline.
  Future<AiJobResult> execute(AiJobRequest request);

  /// Releases native resources (models, isolates, sockets).
  Future<void> dispose() async {}
}

/// Speech -> timed captions.
///
/// Providers `extend` this class: they inherit the capability tag and only
/// implement the typed call plus the [AiService] members.
abstract class AiAutoCaptionService extends AiService {
  @override
  AiCapability get capability => AiCapability.autoCaptions;

  /// Transcribes [mediaPath] into segment-level captions.
  ///
  /// Providers return raw segments; the bridge converts them into text layers
  /// so no provider ever touches the timeline directly.
  Future<List<AiCaptionSegment>> transcribe(
    String mediaPath, {
    String? languageCode,
    bool wordLevelTimings = false,
  });
}

/// Foreground/background separation.
abstract class AiBackgroundRemovalService extends AiService {
  @override
  AiCapability get capability => AiCapability.backgroundRemoval;

  /// Produces an alpha matte for [mediaPath]. [temporalSmoothing] trades CPU
  /// for stable edges across frames (important for 2GB devices).
  Future<AiAlphaMatte> removeBackground(
    String mediaPath, {
    String? outputPath,
    bool temporalSmoothing = true,
  });
}

/// Text -> speech track generation.
abstract class AiVoiceoverService extends AiService {
  @override
  AiCapability get capability => AiCapability.voiceoverTts;

  /// Synthesises [text] into [outputPath] and returns the written file.
  Future<String> synthesize(
    String text, {
    required String outputPath,
    String? voiceId,
    String? languageCode,
    double speed = 1.0,
  });
}

/// Super-resolution.
abstract class AiUpscalerService extends AiService {
  @override
  AiCapability get capability => AiCapability.videoUpscale;

  /// Upscales [mediaPath] by [factor]; returns the produced file.
  Future<String> upscale(
    String mediaPath, {
    required AiUpscaleFactor factor,
    String? outputPath,
  });
}

// -----------------------------------------------------------------------------
// Placeholder provider
// -----------------------------------------------------------------------------

/// Explicit "AI exists but is not set up yet" provider.
///
/// Registering this keeps the bridge's routing table complete and makes the
/// unconfigured state visible in the UI instead of silently missing.
class NoopAiService implements AiService {
  NoopAiService({required this.capability, String? name})
      : _name = name ?? 'unconfigured-${capability.name}';

  @override
  final AiCapability capability;

  final String _name;

  @override
  AiProviderConfig get config =>
      AiProviderConfig(name: _name, capability: capability, enabled: false);

  @override
  bool get isConfigured => false;

  @override
  String get status =>
      'Not configured - add an API key or install the on-device model.';

  @override
  Future<AiJobResult> execute(AiJobRequest request) async =>
      AiJobResult.unavailable(request, status);

  @override
  Future<void> dispose() async {}
}

// -----------------------------------------------------------------------------
// UI-facing description
// -----------------------------------------------------------------------------

/// Description of one staged capability for the settings screen.
@immutable
class AiProviderDescriptor {
  const AiProviderDescriptor({
    required this.capability,
    required this.providerName,
    required this.configured,
    required this.requiresNetwork,
    required this.enabled,
    required this.available,
    this.status = '',
  });

  final AiCapability capability;

  /// Registered provider name ("mopus-cloud", "local-ncnn", ...).
  final String providerName;

  /// Provider has key/model/endpoint.
  final bool configured;

  /// Transport hint from the capability (overridable by the provider).
  final bool requiresNetwork;

  /// User opted into this capability.
  final bool enabled;

  /// Bridge would currently route a request (configured + enabled + transport).
  final bool available;

  final String status;

  /// Label for feature rows: e.g. "Auto Captions - mopus-cloud".
  String get label => '${capability.label} - $providerName';

  @override
  String toString() => 'AiProviderDescriptor($label, available: $available)';
}

// -----------------------------------------------------------------------------
// Pipeline hooks
// -----------------------------------------------------------------------------

/// Hooks the editing/export pipeline exposes to AI features.
///
/// The default implementation is a no-op, so the renderer can call these
/// unconditionally: today they change nothing, tomorrow a provider replaces
/// them without the renderer knowing AI exists.
abstract class AiPipelineHooks {
  const AiPipelineHooks();

  /// Called before a layer's media enters the render graph.
  ///
  /// Return a replacement path (upscaled, background-removed, ...) or `null` to
  /// keep the original. Never called for procedural layers.
  Future<String?> resolveRenderAsset(
    String mediaPath, {
    AiCapability? intent,
  }) async =>
      null;

  /// Called after a successful export (providers may sync previews or clean
  /// temp files).
  Future<void> onExportCompleted(String outputPath) async {}

  /// Called when the project closes so providers can release resources.
  Future<void> onSessionClosed() async {}
}

/// Default no-op hooks - what the app uses until AI is enabled.
class NoopAiPipelineHooks extends AiPipelineHooks {
  const NoopAiPipelineHooks();
}

// -----------------------------------------------------------------------------
// Bridge
// -----------------------------------------------------------------------------

/// Facade that routes AI requests to registered providers.
///
/// Lifetime: one instance per app session, created next to the controllers.
/// Registration is explicit, so a capability without a provider (or without the
/// user's opt-in) fails fast with [AiJobResult.unavailable] and zero side
/// effects.
///
/// ```dart
/// final bridge = AiIntegrationBridge(
///   config: AiStagingConfig.offlineDefault.copyWith(
///     allowNetwork: true,
///     enabledCapabilities: {AiCapability.autoCaptions},
///   ),
/// );
/// bridge.register(MyCloudCaptionProvider(config: providerConfig));
///
/// final result = await bridge.execute(AiJobRequest(
///   capability: AiCapability.autoCaptions,
///   inputPath: '/media/interview.mp4',
/// ));
/// ```
class AiIntegrationBridge {
  AiIntegrationBridge({
    AiStagingConfig? config,
    AiCredentialStore? credentials,
    AiPipelineHooks? hooks,
  })  : _config = config ?? AiStagingConfig.offlineDefault,
        credentials = credentials ?? InMemoryAiCredentialStore(),
        hooks = hooks ?? const NoopAiPipelineHooks();

  AiStagingConfig _config;

  /// Key store handed to providers at setup time.
  final AiCredentialStore credentials;

  /// Pipeline callbacks (no-op by default).
  final AiPipelineHooks hooks;

  final Map<AiCapability, AiService> _services = <AiCapability, AiService>{};
  int _requestCounter = 0;

  /// Current staging switches.
  AiStagingConfig get config => _config;

  /// Replaces the staging switches (settings screen).
  set config(AiStagingConfig value) => _config = value;

  /// Registered providers, keyed by capability.
  Map<AiCapability, AiService> get services =>
      Map<AiCapability, AiService>.unmodifiable(_services);

  /// Registers (or replaces) the provider for its capability.
  void register(AiService service) {
    _services[service.capability] = service;
  }

  /// Removes and disposes the provider for [capability].
  Future<void> unregister(AiCapability capability) async {
    final service = _services.remove(capability);
    await service?.dispose();
  }

  /// Provider currently handling [capability], if any.
  AiService? serviceFor(AiCapability capability) => _services[capability];

  /// `true` when a request for [capability] would currently be routed.
  bool isAvailable(AiCapability capability) {
    final service = _services[capability];
    if (service == null || !service.isConfigured) return false;
    if (!_config.allows(capability)) return false;
    if (!_config.transportAllowed(capability)) return false;
    return service.config.enabled;
  }

  /// Capabilities that would be routed right now.
  List<AiCapability> get availableCapabilities => AiCapability.values
      .where(isAvailable)
      .toList(growable: false);

  /// Snapshot for the settings screen (one row per capability).
  List<AiProviderDescriptor> describeProviders() => AiCapability.values
      .map((capability) {
        final service = _services[capability];
        return AiProviderDescriptor(
          capability: capability,
          providerName: service?.config.name ?? 'none',
          configured: service?.isConfigured ?? false,
          requiresNetwork: capability.defaultRequiresNetwork,
          enabled: _config.allows(capability),
          available: isAvailable(capability),
          status: service?.status ?? 'No provider registered.',
        );
      })
      .toList(growable: false);

  /// Routes [request] through the registered provider.
  ///
  /// Guards run in order: registered -> configured -> opted in -> transport.
  /// Every guard returns a failed [AiJobResult]; nothing throws here.
  Future<AiJobResult> execute(AiJobRequest request) async {
    final prepared = request.requestId.isEmpty
        ? AiJobRequest(
            capability: request.capability,
            inputPath: request.inputPath,
            outputPath: request.outputPath,
            parameters: request.parameters,
            requestId: _nextRequestId(request.capability),
          )
        : request;

    final service = _services[prepared.capability];
    if (service == null) {
      return AiJobResult.unavailable(
          prepared, 'No provider registered for ${prepared.capability.label}.');
    }
    if (!service.isConfigured) {
      return AiJobResult.unavailable(prepared, service.status);
    }
    if (!_config.allows(prepared.capability)) {
      return AiJobResult.unavailable(
        prepared,
        '${prepared.capability.label} is staged but not enabled in settings.',
      );
    }
    if (!_config.transportAllowed(prepared.capability)) {
      return AiJobResult.unavailable(
        prepared,
        prepared.capability.defaultRequiresNetwork
            ? 'Network AI features are disabled (offline mode).'
            : 'On-device AI models are disabled in settings.',
      );
    }

    final stopwatch = Stopwatch()..start();
    try {
      final result = await service.execute(prepared);
      return AiJobResult(
        requestId: result.requestId.isEmpty ? prepared.requestId : result.requestId,
        capability: result.capability,
        succeeded: result.succeeded,
        outputPath: result.outputPath,
        payload: result.payload,
        errorMessage: result.errorMessage,
        duration: result.duration == Duration.zero
            ? stopwatch.elapsed
            : result.duration,
      );
    } catch (error) {
      // Providers should return failures; a throw is a bug we contain here so
      // one broken plugin can never take the editor down.
      return AiJobResult(
        requestId: prepared.requestId,
        capability: prepared.capability,
        succeeded: false,
        errorMessage: 'Provider error: $error',
        duration: stopwatch.elapsed,
      );
    }
  }

  // -- Typed conveniences -----------------------------------------------------

  /// Captions for [mediaPath], or `null` when auto-captions are not available.
  ///
  /// Callers treat `null` as "no AI here, keep going" - that is the contract
  /// that lets the editing code stay AI-agnostic.
  Future<List<AiCaptionSegment>?> tryTranscribe(
    String mediaPath, {
    String? languageCode,
  }) async {
    final capability = AiCapability.autoCaptions;
    final service = _services[capability];
    if (service is! AiAutoCaptionService || !isAvailable(capability)) {
      return null;
    }
    try {
      final segments = await service.transcribe(
        mediaPath,
        languageCode: languageCode,
      );
      final valid = segments.where((segment) => segment.isValid).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      return valid;
    } catch (_) {
      return null;
    }
  }

  /// Background-removed matte, or `null` when unavailable.
  Future<AiAlphaMatte?> tryRemoveBackground(String mediaPath) async {
    final capability = AiCapability.backgroundRemoval;
    final service = _services[capability];
    if (service is! AiBackgroundRemovalService || !isAvailable(capability)) {
      return null;
    }
    try {
      return await service.removeBackground(mediaPath);
    } catch (_) {
      return null;
    }
  }

  /// Voiceover file for [text], or `null` when unavailable.
  Future<String?> trySynthesize(
    String text, {
    required String outputPath,
    String? voiceId,
  }) async {
    final capability = AiCapability.voiceoverTts;
    final service = _services[capability];
    if (service is! AiVoiceoverService || !isAvailable(capability)) {
      return null;
    }
    try {
      return await service.synthesize(text,
          outputPath: outputPath, voiceId: voiceId);
    } catch (_) {
      return null;
    }
  }

  /// Upscaled copy of [mediaPath], or a copy of the original path when the
  /// upscaler is not available (so callers can always chain unconditionally).
  Future<String> tryUpscale(
    String mediaPath, {
    required AiUpscaleFactor factor,
  }) async {
    final capability = AiCapability.videoUpscale;
    final service = _services[capability];
    if (service is! AiUpscalerService || !isAvailable(capability)) {
      return mediaPath;
    }
    try {
      return await service.upscale(mediaPath, factor: factor);
    } catch (_) {
      return mediaPath;
    }
  }

  // -- Timeline binding -------------------------------------------------------

  /// Writes [segments] onto [controller] as text layers and returns how many
  /// were created.
  ///
  /// This is the single place where AI output meets the editing model: layers
  /// are ordinary text layers, so every existing tool (trim, transform,
  /// keyframes, export) works on captions with zero special cases. When the
  /// segment list is empty the project is untouched.
  int applyCaptions(
    TimelineController controller,
    List<AiCaptionSegment> segments, {
    String namingPrefix = '',
  }) {
    if (segments.isEmpty) return 0;
    var created = 0;
    for (final segment in segments) {
      if (!segment.isValid) continue;
      final layer = controller.addLayerOfType(
        LayerType.text,
        startTime: segment.start,
        duration: segment.duration,
      );
      controller.renameLayer(layer.id, '$namingPrefix${segment.text}');
      created++;
    }
    return created;
  }

  /// Releases every registered provider.
  Future<void> dispose() async {
    for (final service in _services.values) {
      await service.dispose();
    }
    _services.clear();
  }

  String _nextRequestId(AiCapability capability) =>
      'ai-${capability.name}-${DateTime.now().microsecondsSinceEpoch}-'
      '${_requestCounter++}';
}
