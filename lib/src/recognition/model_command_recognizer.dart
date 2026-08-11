import 'dart:async';

import '../engine/wake_word_engine.dart';
import '../platform/voice_notifier.dart';
import 'command_recognizer.dart';

/// Fully offline command recognition.
///
/// The wake word opens a short session that hot-swaps the engine's active
/// models to just the commands valid right now; the next detection *is* the
/// command. No speech-to-text is involved, so it works on platforms that have
/// none and while the network is down.
///
/// Also used as the fallback inside [SttCommandRecognizer] when speech-to-text
/// cannot run, which is why the session is exposed through
/// [openSessionOrDispatch] rather than being private to [handleDetection].
final class ModelCommandRecognizer implements CommandRecognizer {
  ModelCommandRecognizer({
    required VoiceRecognizerContext context,
    this.sessionTimeout = const Duration(seconds: 7),
  }) : _context = context;

  final VoiceRecognizerContext _context;

  /// How long to wait for a command before giving up and going back to the
  /// wake word.
  final Duration sessionTimeout;

  bool _sessionActive = false;
  Timer? _sessionTimer;

  @override
  bool get hasActiveSession => _sessionActive;

  @override
  Future<void> handleDetection(WakeWordDetection detection) {
    return openSessionOrDispatch(detection);
  }

  /// Opens a command session on a wake-word detection, or treats any other
  /// detection as the command itself.
  Future<void> openSessionOrDispatch(WakeWordDetection detection) async {
    final isWakeWord = detection.modelId == _context.wakeWordId;

    if (_sessionActive) {
      // Inside a session, anything that is not the wake word is the command.
      if (!isWakeWord) {
        await _handleCommand(detection.modelId);
      }
      return;
    }

    if (isWakeWord) {
      await startSession();
      return;
    }

    // A command model fired without a session — the user skipped the wake
    // word, or a session had just timed out. Honour it anyway.
    await _handleCommand(detection.modelId);
  }

  /// Swaps the engine onto the currently-available command models and waits for
  /// one of them.
  Future<void> startSession() async {
    final modelIds = _availableModelIds();
    if (modelIds.isEmpty) {
      // Nothing could be recognised, so opening a session would only strand the
      // user in a listening state that cannot end well.
      _context.logger.warn(
        'ModelCommandRecognizer: no command models available, ignoring wake word',
      );
      _context.notifier.notify(VoiceFeedback.commandUnavailable);
      return;
    }

    _sessionActive = true;
    _context.notifier.notify(VoiceFeedback.listening);

    // Awaited so model loading is serialized against the next detection.
    await _context.listener.start(modelIds: modelIds);

    _sessionTimer?.cancel();
    _sessionTimer = Timer(sessionTimeout, () {
      unawaited(closeSession(handled: false));
    });
  }

  /// Ids of commands that are both offered right now and have a model to
  /// detect them with.
  List<String> _availableModelIds() {
    final available = _context.availableCommandIds().toSet();
    return _context.commands
        .where(
          (command) =>
              available.contains(command.id) && command.classifier != null,
        )
        .map((command) => command.id)
        .toList();
  }

  Future<void> _handleCommand(String commandId) async {
    try {
      final dispatched = await _context.dispatch(commandId);
      if (!dispatched) {
        _context.notifier.notify(VoiceFeedback.commandUnavailable);
      }
    } finally {
      await closeSession(handled: true);
    }
  }

  Future<void> closeSession({required bool handled}) async {
    if (!_sessionActive) return;
    _sessionActive = false;

    _sessionTimer?.cancel();
    _sessionTimer = null;

    if (!handled) {
      _context.notifier.notify(VoiceFeedback.noCommandDetected);
    }

    await _context.resumeBackgroundListener();
  }

  @override
  Future<void> abortSession({required bool resumeListener}) async {
    _sessionTimer?.cancel();
    _sessionTimer = null;
    _sessionActive = false;

    if (resumeListener) {
      await _context.resumeBackgroundListener();
    }
  }

  @override
  Future<void> dispose() async {
    _sessionTimer?.cancel();
    _sessionTimer = null;
  }
}
