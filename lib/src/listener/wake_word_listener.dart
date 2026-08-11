import 'dart:async';
import 'dart:typed_data';

import '../audio/wake_word_audio_channel.dart';
import '../engine/wake_word_engine.dart';
import '../platform/voice_logger.dart';
import '../util/async_lock.dart';
import 'wake_word_capture.dart';

/// Keeps microphone capture and the wake-word engine running together.
///
/// Everything about *whether* listening is wanted — a settings toggle, whether
/// a user is signed in — belongs to the caller: this starts when told to and
/// stops when told to.
final class WakeWordListener implements WakeWordCapture {
  WakeWordListener({
    required WakeWordEngine engine,
    VoiceLogger logger = const SilentVoiceLogger(),
    this.onEngineInitFailed,
  }) : _engine = engine,
       _logger = logger;

  final WakeWordEngine _engine;
  final VoiceLogger _logger;
  final _lock = AsyncLock();

  /// Called every time [WakeWordEngine.init] fails to load — including on
  /// every automatic health-check retry, not just the first attempt, since
  /// this listener has no way to know on its own whether a given failure is
  /// worth telling apart from the last one.
  ///
  /// Without this, the only sign of a broken model was a log line repeating
  /// forever: the health check treats a failed [start] exactly like "no
  /// microphone yet" and keeps retrying, which is the right default for that
  /// case but means a [ModelLoadFailure] — permanent, nothing to wait out —
  /// looks identical from the outside. Catch that type here to tell them
  /// apart; what to do about it (call [stop], surface it to the user, report
  /// it to crash analytics, or nothing at all) is left to the host, same as
  /// every other judgement call this package hands back rather than makes
  /// itself.
  final void Function(Object error, StackTrace stackTrace)? onEngineInitFailed;

  StreamSubscription<Int16List>? _pcmSubscription;
  bool _running = false;
  bool _engineReady = false;
  List<String>? _activeModelIds;
  bool _handlingDetection = false;
  Future<void> Function(WakeWordDetection detection)? _onDetection;
  Completer<void>? _firstPcmCompleter;
  DateTime? _lastPcmTime;

  /// How long to wait for the first PCM chunk before treating a start as
  /// failed. Capture that never delivers audio is worse than a clean failure:
  /// the caller would believe it is listening.
  static const Duration _firstPcmTimeout = Duration(milliseconds: 1000);

  /// Called for each detection. Re-entrant calls are dropped while one is in
  /// flight, so a slow handler cannot pile up.
  void setDetectionHandler(
    Future<void> Function(WakeWordDetection detection)? handler,
  ) {
    _onDetection = handler;
  }

  /// Starts capture with [modelIds] eligible to fire.
  ///
  /// When capture is already running this only swaps the active models, which
  /// is what makes a mid-session switch from wake word to command phrases cheap
  /// enough to do without dropping audio.
  @override
  Future<bool> start({required List<String> modelIds}) {
    return _lock.run(() => _startInternal(modelIds));
  }

  Future<bool> _startInternal(List<String> modelIds) async {
    _logger.info('WakeWordListener: start', {'models': modelIds});

    if (!WakeWordAudioChannel.isSupported) {
      return false;
    }

    final nativeListening = await WakeWordAudioChannel.isListening();
    if (_running && nativeListening) {
      if (_sameModels(_activeModelIds, modelIds)) {
        _logger.info('WakeWordListener: already running with these models');
        return true;
      }

      _logger.info('WakeWordListener: in-place model switch', {
        'from': _activeModelIds,
        'to': modelIds,
      });
      _engine.setActive(modelIds);
      _activeModelIds = modelIds;
      return true;
    }

    try {
      final permissionGranted = await WakeWordAudioChannel.requestPermission();
      if (!permissionGranted) {
        _logger.warn('WakeWordListener: microphone permission not granted');
        return false;
      }

      if (!_engineReady) {
        try {
          _logger.info('WakeWordListener: initializing engine');
          await _engine.init();
          _engineReady = true;
        } on Object catch (error, stackTrace) {
          _logger.error(
            'WakeWordListener: engine init failed',
            error: error,
            stackTrace: stackTrace,
          );
          onEngineInitFailed?.call(error, stackTrace);
          return false;
        }
      }

      _engine.setActive(modelIds);
      _activeModelIds = modelIds;

      _pcmSubscription ??= WakeWordAudioChannel.pcmStream().listen(
        _handlePcmChunk,
        onError: (Object error, StackTrace stackTrace) {
          _logger.error(
            'WakeWordListener: PCM stream error',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );

      _firstPcmCompleter = Completer<void>();

      await WakeWordAudioChannel.startListening();
      _running = true;

      try {
        await _firstPcmCompleter!.future.timeout(_firstPcmTimeout);
        _logger.info('WakeWordListener: started, PCM streaming');
        return true;
      } on TimeoutException {
        _logger.warn('WakeWordListener: no PCM after start, stopping');
        await _stopInternal();
        return false;
      } finally {
        _firstPcmCompleter = null;
      }
    } on Object catch (error, stackTrace) {
      _firstPcmCompleter = null;
      _logger.error(
        'WakeWordListener: start failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  void _handlePcmChunk(Int16List pcm) {
    _lastPcmTime = DateTime.now();

    final firstPcm = _firstPcmCompleter;
    if (firstPcm != null && !firstPcm.isCompleted) {
      firstPcm.complete();
    }

    try {
      final detection = _engine.processPcm(pcm);
      if (detection == null) return;

      _logger.info('WakeWordListener: detected', {
        'model': detection.modelId,
        'score': detection.score,
      });

      final handler = _onDetection;
      if (handler == null) return;
      if (_handlingDetection) return;

      _handlingDetection = true;
      unawaited(_runDetectionHandler(handler, detection));
    } on Object catch (error, stackTrace) {
      _logger.error(
        'WakeWordListener: processing failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _runDetectionHandler(
    Future<void> Function(WakeWordDetection detection) handler,
    WakeWordDetection detection,
  ) async {
    try {
      await handler(detection);
    } finally {
      _handlingDetection = false;
    }
  }

  @override
  Future<void> stop() => _lock.run(_stopInternal);

  Future<void> _stopInternal() async {
    if (!WakeWordAudioChannel.isSupported) return;

    await WakeWordAudioChannel.stopListening();
    _running = false;
    await _pcmSubscription?.cancel();
    _pcmSubscription = null;
    if (_engineReady) {
      _engine.reset();
    }
    _logger.info('WakeWordListener: stopped');
  }

  Future<void> dispose() => _lock.run(_disposeInternal);

  Future<void> _disposeInternal() async {
    await _stopInternal();
    if (_engineReady) {
      await _engine.dispose();
    }
    _engineReady = false;
    _activeModelIds = null;
    _lastPcmTime = null;
  }

  /// Whether capture is (believed to be) running. `false` covers both
  /// "intentionally stopped" and "start() failed" — e.g. no microphone
  /// connected — so a caller that wants to retry a failed start should use this
  /// rather than [isHealthy], which treats not-running as fine.
  bool get isRunning => _running;

  /// Whether audio is actually arriving. A capture that has gone silent while
  /// it should be running is the failure mode a watchdog is looking for.
  bool get isHealthy {
    if (!_running) return true; // Intentionally stopped, not unhealthy.
    final lastPcmTime = _lastPcmTime;
    if (lastPcmTime == null) return false; // Never started receiving PCM.
    return DateTime.now().difference(lastPcmTime).inSeconds < 3;
  }

  static bool _sameModels(List<String>? a, List<String>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
