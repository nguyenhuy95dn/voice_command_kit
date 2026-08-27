import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../audio/wake_word_audio_channel.dart';
import '../config/voice_command.dart';
import '../config/voice_pipeline_config.dart';
import '../engine/wake_word_engine.dart';
import '../listener/wake_word_listener.dart';
import '../platform/voice_logger.dart';
import '../platform/voice_notifier.dart';
import '../recognition/command_recognizer.dart';
import '../recognition/model_command_recognizer.dart';
import '../recognition/speech_recognizer.dart';
import '../recognition/stt_command_recognizer.dart';

/// Runs voice control end to end: capture, wake word, command recognition, and
/// the watchdog that keeps all three alive.
///
/// It decides nothing about the host app. When listening should happen is the
/// caller's business — call [start] and [stop]. Which commands are offered at
/// any moment comes from `availableCommands`, and what a recognised command
/// *does* is entirely `onCommand`. The same goes for failure: `onEngineInitFailed`
/// reports a broken configuration rather than acting on it — the pipeline
/// itself never decides that a failure is bad enough to stop listening over.
final class VoicePipeline implements VoiceRecognizerContext {
  VoicePipeline({
    required VoicePipelineConfig config,
    required Future<bool> Function(String commandId) onCommand,
    List<String> Function()? availableCommands,
    bool Function()? canUseSpeechToTextNow,
    /// Reports every failure to load the wake word engine, including on every
    /// automatic health-check retry — not just the first. A [ModelLoadFailure]
    /// specifically means a model is missing or misconfigured, which retrying
    /// will never fix on its own; anything else might be transient. Deciding
    /// what to do about either — keep listening quietly, call [stop], surface
    /// it to the user — is left entirely to the host. Ignored when [listener]
    /// is supplied directly, since this constructor did not build it.
    void Function(Object error, StackTrace stackTrace)? onEngineInitFailed,
    VoiceLogger logger = const SilentVoiceLogger(),
    VoiceNotifier notifier = const SilentVoiceNotifier(),
    SpeechRecognizer? speechRecognizer,
    WakeWordEngine? engine,
    WakeWordListener? listener,
  }) : _config = config,
       _onCommand = onCommand,
       _availableCommands = availableCommands,
       _canUseSpeechToText = canUseSpeechToTextNow,
       _logger = logger,
       _notifier = notifier {
    _validateConfig(config);

    final wakeWordEngine =
        engine ??
        WakeWordEngine(
          features: config.features,
          models: [
            config.wakeWord,
            for (final command in config.commands) ?command.wakeWordModel,
          ],
          cooldown: config.detectionCooldown,
        );

    // onEngineInitFailed only reaches a listener this constructor builds
    // itself — a caller supplying its own [listener] already decided how it
    // wants that listener wired.
    _listener =
        listener ??
        WakeWordListener(
          engine: wakeWordEngine,
          logger: logger,
          onEngineInitFailed: onEngineInitFailed,
        );
    _listener.setDetectionHandler(_onDetection);

    _recognizer = switch (_resolveMode(config.mode)) {
      CommandRecognitionMode.speechToText => SttCommandRecognizer(
        context: this,
        speechRecognizer: speechRecognizer ?? SpeechToTextRecognizer(),
        localeId: config.locale,
        listenFor: config.speechListenFor,
        pauseFor: config.speechPauseFor,
        sessionTimeout: config.speechSessionTimeout,
        offlineFallback: ModelCommandRecognizer(
          context: this,
          sessionTimeout: config.commandSessionTimeout,
        ),
      ),
      _ => ModelCommandRecognizer(
        context: this,
        sessionTimeout: config.commandSessionTimeout,
      ),
    };

    // React the moment the microphone we capture from changes, instead of
    // waiting for the next health-check tick. deviceEventStream() guards
    // itself to macOS — the listen-call failure that guard avoids surfaces
    // via FlutterError.reportError, not this onError, so it could never be
    // caught here. The MissingPluginException check below stays as
    // defense-in-depth for any other failure shape.
    _deviceEventSubscription = WakeWordAudioChannel.deviceEventStream().listen(
      (event) {
        _logger.info('VoicePipeline: audio device event', {'event': event});
        unawaited(_handleInputDeviceChanged());
      },
      onError: (Object error, StackTrace stackTrace) {
        if (error is MissingPluginException) return;
        _logger.error(
          'VoicePipeline: device event stream error',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  final VoicePipelineConfig _config;
  final Future<bool> Function(String commandId) _onCommand;
  final List<String> Function()? _availableCommands;
  final bool Function()? _canUseSpeechToText;
  final VoiceLogger _logger;
  final VoiceNotifier _notifier;

  late final WakeWordListener _listener;
  late final CommandRecognizer _recognizer;
  StreamSubscription<String>? _deviceEventSubscription;

  bool _disposed = false;
  bool _allowResume = false;
  Timer? _healthCheckTimer;

  /// `true` while the pipeline was taken down on purpose. The watchdog leaves
  /// capture alone in that case; any *other* down state is treated as a fault
  /// it may recover from.
  bool _suspended = true;

  /// Whether the pipeline is currently meant to be listening.
  bool get isRunning => !_suspended && !_disposed;

  /// Begins listening for the wake word. Safe to call when already running.
  Future<void> start() async {
    if (_disposed || !WakeWordAudioChannel.isSupported) {
      _logger.warn('VoicePipeline: start skipped', {
        'disposed': _disposed,
        'platform': Platform.operatingSystem,
      });
      return;
    }

    _suspended = false;
    _allowResume = true;

    await _listener.start(modelIds: [_config.wakeWord.id]);
    _startHealthCheckTimer();

    _logger.info('VoicePipeline: started', {
      'platform': Platform.operatingSystem,
      'mode': _resolveMode(_config.mode).name,
    });
  }

  /// Stops listening and abandons any command session in progress.
  Future<void> stop() async {
    if (!WakeWordAudioChannel.isSupported) return;

    _suspended = true;
    _allowResume = false;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    await _recognizer.abortSession(resumeListener: false);
    await _listener.stop();

    _logger.info('VoicePipeline: stopped');
  }

  /// Abandons a command session in progress and returns to the wake word,
  /// without stopping the pipeline.
  ///
  /// For hosts whose state can invalidate a session mid-flight — the screen the
  /// commands belonged to went away, the activity they would have controlled
  /// ended. No-ops when no session is open.
  Future<void> abortCommandSession() async {
    if (_disposed || !_recognizer.hasActiveSession) return;

    _logger.info('VoicePipeline: aborting command session on host request');
    await _recognizer.abortSession(resumeListener: true);
  }

  Future<void> dispose() async {
    _disposed = true;
    _allowResume = false;

    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    await _deviceEventSubscription?.cancel();
    _deviceEventSubscription = null;
    await _recognizer.dispose();
    await _listener.dispose();
  }

  Future<void> _onDetection(WakeWordDetection detection) async {
    if (_disposed || _suspended) return;
    await _recognizer.handleDetection(detection);
  }

  /// The microphone the listener was capturing from changed.
  ///
  /// The native plugin has already torn its capture engine down by the time
  /// this runs — it cannot wait for a round trip through Dart while a tap may
  /// still be installed on hardware that just went away. So there is nothing to
  /// decide here beyond bringing capture back up on whatever the new input
  /// device is; "same device as before" would need a restart just the same.
  Future<void> _handleInputDeviceChanged() async {
    if (_disposed || !_allowResume || _recognizer.hasActiveSession) return;

    await _listener.stop();
    await resumeBackgroundListener();
  }

  void _startHealthCheckTimer() {
    if (!WakeWordAudioChannel.isSupported) return;
    _healthCheckTimer ??= Timer.periodic(
      _config.healthCheckInterval,
      (_) => unawaited(_performHealthCheck()),
    );
  }

  /// Recovers a stalled capture stream, and retries a start that previously
  /// failed — e.g. because no microphone was connected. Plugging one in later
  /// is picked up on the next tick rather than needing the user to toggle voice
  /// control off and on.
  Future<void> _performHealthCheck() async {
    if (_disposed || _suspended || _recognizer.hasActiveSession) return;

    if (!_allowResume) {
      // Something took resume off while listening was still expected. Heal,
      // rather than staying silent for the rest of the app's life.
      _logger.warn('VoicePipeline: resume was disabled while running, re-enabling');
      _allowResume = true;
    }

    if (!_listener.isRunning) {
      _logger.info('VoicePipeline: capture not running, retrying start');
      await _listener.start(modelIds: [_config.wakeWord.id]);
      return;
    }

    if (!_listener.isHealthy) {
      _logger.warn('VoicePipeline: no audio arriving, forcing recovery');
      await _listener.stop();
      await resumeBackgroundListener();
    }
  }

  static CommandRecognitionMode _resolveMode(CommandRecognitionMode mode) {
    if (mode != CommandRecognitionMode.auto) return mode;
    // Windows has no speech-to-text worth relying on.
    return Platform.isWindows
        ? CommandRecognitionMode.wakeWordModel
        : CommandRecognitionMode.speechToText;
  }

  static void _validateConfig(VoicePipelineConfig config) {
    final ids = <String>{config.wakeWord.id};
    for (final command in config.commands) {
      if (!ids.add(command.id)) {
        throw ArgumentError(
          'Command id "${command.id}" collides with another command or the '
          'wake word. Ids identify models to the engine, so they must be '
          'unique.',
        );
      }
      if (!command.isRecognisable) {
        throw ArgumentError(
          'Command "${command.id}" has neither phrases nor a classifier, so '
          'nothing could ever recognise it.',
        );
      }
    }
  }

  // ===========================================================================
  // VoiceRecognizerContext
  // ===========================================================================

  @override
  WakeWordListener get listener => _listener;

  @override
  VoiceLogger get logger => _logger;

  @override
  VoiceNotifier get notifier => _notifier;

  @override
  bool get isDisposed => _disposed;

  @override
  String get wakeWordId => _config.wakeWord.id;

  @override
  List<VoiceCommand> get commands => _config.commands;

  @override
  List<String> availableCommandIds() {
    final available = _availableCommands;
    if (available == null) {
      return [for (final command in _config.commands) command.id];
    }
    return available();
  }

  @override
  bool canUseSpeechToText() => _canUseSpeechToText?.call() ?? true;

  @override
  Future<bool> dispatch(String commandId) async {
    _logger.info('VoicePipeline: dispatching', {'command': commandId});
    try {
      return await _onCommand(commandId);
    } catch (error, stackTrace) {
      _logger.error(
        'VoicePipeline: command handler threw',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Restarts background wake-word listening after a command session.
  ///
  /// A single attempt is made here; recovery from a stalled stream is the
  /// watchdog's job.
  @override
  Future<void> resumeBackgroundListener() async {
    if (_disposed || !_allowResume) return;

    // Apple platforms (iOS & macOS) need a short settle delay after releasing
    // the microphone (e.g. from speech-to-text) before the audio session /
    // engine can be re-acquired reliably.
    if (Platform.isIOS || Platform.isMacOS) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    if (_disposed || !_allowResume) return;

    try {
      await _listener.start(modelIds: [_config.wakeWord.id]);
    } catch (error, stackTrace) {
      _logger.error(
        'VoicePipeline: failed to resume listening',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
