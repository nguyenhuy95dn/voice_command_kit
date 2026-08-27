import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../config/voice_command.dart';
import '../engine/wake_word_engine.dart';
import '../platform/voice_notifier.dart';
import 'command_recognizer.dart';
import 'model_command_recognizer.dart';
import 'speech_recognizer.dart';

/// Speech-to-text command recognition.
///
/// The wake word releases the microphone and opens a speech session; the
/// transcript is matched against each command's phrases.
///
/// When the host reports that speech-to-text cannot run right now — typically
/// because something else is holding the microphone — the session falls back to
/// [ModelCommandRecognizer] for that turn, so commands that carry a classifier
/// still work.
final class SttCommandRecognizer implements CommandRecognizer {
  SttCommandRecognizer({
    required VoiceRecognizerContext context,
    required SpeechRecognizer speechRecognizer,
    this.localeId = 'en_US',
    this.listenFor = const Duration(seconds: 6),
    this.pauseFor = const Duration(seconds: 5),
    this.sessionTimeout = const Duration(seconds: 8),
    ModelCommandRecognizer? offlineFallback,
  }) : _context = context,
       _speech = speechRecognizer,
       _offline =
           offlineFallback ?? ModelCommandRecognizer(context: context);

  final VoiceRecognizerContext _context;
  final SpeechRecognizer _speech;
  final ModelCommandRecognizer _offline;

  /// Locale to recognise in. Commands are matched by phrase, so this should be
  /// the language the configured phrases are written in — not the device
  /// locale, which may differ.
  final String localeId;

  final Duration listenFor;
  final Duration pauseFor;
  final Duration sessionTimeout;

  /// How long to wait after the engine reports it stopped, in case a final
  /// transcript is still on its way.
  static const Duration _closeAfterStatusDelay = Duration(milliseconds: 1200);

  bool _speechInitialized = false;
  bool _speechAvailable = false;

  Timer? _sessionTimeoutTimer;
  Timer? _closeAfterStatusTimer;

  bool _sessionActive = false;
  bool _sessionClosing = false;
  bool _commandHandled = false;
  String _bestTranscript = '';

  @override
  bool get hasActiveSession =>
      _sessionActive || _sessionClosing || _offline.hasActiveSession;

  @override
  Future<void> handleDetection(WakeWordDetection detection) async {
    if (_sessionActive || _sessionClosing) return;

    // A fallback session is running: this detection is one of its command
    // models, not a wake word.
    if (_offline.hasActiveSession) {
      await _offline.openSessionOrDispatch(detection);
      return;
    }

    try {
      if (!_context.canUseSpeechToText()) {
        _context.logger.info(
          'SttCommandRecognizer: speech-to-text unavailable, using models',
        );
        await _offline.openSessionOrDispatch(detection);
        return;
      }

      // Speech-to-text needs the microphone the wake-word engine is holding.
      // Native stopListening() completes asynchronously once CoreAudio has fully
      // drained and released the hardware IOUnit.
      await _context.listener.stop();

      _context.notifier.notify(VoiceFeedback.listening);

      final initialized = await _initializeSpeech();
      if (!initialized) {
        _context.logger.warn(
          'SttCommandRecognizer: speech-to-text initialization failed, falling back to offline models',
        );
        // Fallback to offline command classifier models
        await _offline.openSessionOrDispatch(detection);
        return;
      }

      _openSession();

      try {
        await _speech.listen(
          onResult: _onSpeechResult,
          localeId: localeId,
          listenFor: listenFor,
          pauseFor: pauseFor,
        );
        _context.logger.info('SttCommandRecognizer: speech session started');
      } catch (e, st) {
        _context.logger.error(
          'SttCommandRecognizer: speech listen call failed, falling back to offline models',
          error: e,
          stackTrace: st,
        );
        _cancelTimers();
        _sessionActive = false;
        await _offline.openSessionOrDispatch(detection);
      }
    } catch (error, stackTrace) {
      _context.logger.error(
        'SttCommandRecognizer: failed to start speech session, falling back',
        error: error,
        stackTrace: stackTrace,
      );

      try {
        await _offline.openSessionOrDispatch(detection);
      } catch (_) {
        await _context.resumeBackgroundListener();
      }
    }
  }

  @override
  Future<void> abortSession({required bool resumeListener}) async {
    _cancelTimers();
    await _speech.stop();

    _sessionActive = false;
    _sessionClosing = false;
    _commandHandled = false;
    _bestTranscript = '';
    await _offline.abortSession(resumeListener: false);

    if (resumeListener) {
      await _context.resumeBackgroundListener();
    }
  }

  @override
  Future<void> dispose() async {
    _cancelTimers();
    await _speech.stop();
    await _offline.dispose();
  }

  Future<bool> _initializeSpeech() async {
    if (_speechInitialized) return _speechAvailable;

    _speechInitialized = true;
    _speechAvailable = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: _onSpeechError,
    );

    _context.logger.info('SttCommandRecognizer: speech initialized', {
      'available': _speechAvailable,
    });

    return _speechAvailable;
  }

  void _onSpeechError(SpeechError error) {
    switch (error.code) {
      case 'error_no_match':
        // Nothing usable heard yet — the session's own timeout decides when to
        // give up, not a single unrecognised burst.
        _context.logger.info('SttCommandRecognizer: no match yet');
        return;

      case 'error_speech_timeout':
        _closeSessionIfNeeded(reason: 'speech_timeout');
        return;

      default:
        _context.logger.error(
          'SttCommandRecognizer: speech error',
          error: error.code,
        );
        _closeSessionIfNeeded(reason: 'speech_error:${error.code}');
        return;
    }
  }

  void _onSpeechResult(SpeechResult result) {
    if (!_sessionActive || _commandHandled) return;

    final words = result.transcript.trim();

    _context.logger.info('SttCommandRecognizer: transcript', {
      'words': words,
      'final': result.isFinal,
    });

    if (words.isNotEmpty &&
        (result.isFinal || words.length > _bestTranscript.length)) {
      _bestTranscript = words;
    }

    final commandId = matchCommand(words, _availableCommands());
    if (commandId == null) return;

    _commandHandled = true;
    unawaited(_executeCommand(commandId));
  }

  void _onSpeechStatus(String status) {
    if (_commandHandled) return;

    final normalized = status.toLowerCase();

    if (normalized != 'done' && normalized != 'notlistening') {
      return;
    }

    if (_bestTranscript.trim().isEmpty) {
      _closeSessionIfNeeded(reason: 'status:$normalized:no_transcript');
      return;
    }

    // Something was heard: give the engine a moment to upgrade a partial
    // transcript into a final one before deciding it matched nothing.
    _closeAfterStatusTimer?.cancel();
    _closeAfterStatusTimer = Timer(_closeAfterStatusDelay, () {
      if (_commandHandled || !_sessionActive || _sessionClosing) return;
      _closeSessionIfNeeded(reason: 'status:$normalized:delayed');
    });
  }

  List<VoiceCommand> _availableCommands() {
    final available = _context.availableCommandIds().toSet();
    return _context.commands
        .where((command) => available.contains(command.id))
        .toList();
  }

  /// Matches [transcript] against [commands], returning the id of the first
  /// command one of whose phrases the transcript contains.
  ///
  /// Punctuation and casing are stripped first, because engines differ on both
  /// for the same spoken words.
  @visibleForTesting
  static String? matchCommand(String transcript, List<VoiceCommand> commands) {
    final normalized = transcript
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (normalized.isEmpty) return null;

    for (final command in commands) {
      for (final phrase in command.phrases) {
        if (normalized.contains(phrase.toLowerCase())) {
          return command.id;
        }
      }
    }

    return null;
  }

  Future<void> _executeCommand(String commandId) async {
    await _speech.stop();

    try {
      final dispatched = await _context.dispatch(commandId);
      if (!dispatched) {
        _context.notifier.notify(VoiceFeedback.commandUnavailable);
      }
    } finally {
      await _closeSession(reason: 'command_done');
    }
  }

  void _openSession() {
    _sessionActive = true;
    _sessionClosing = false;
    _commandHandled = false;
    _bestTranscript = '';

    _cancelTimers();
    _sessionTimeoutTimer = Timer(sessionTimeout, () {
      _context.logger.warn('SttCommandRecognizer: session timeout');
      _closeSessionIfNeeded(reason: 'session_timeout');
    });
  }

  Future<void> _closeSession({required String reason}) async {
    if (!_sessionActive && !_sessionClosing) {
      await _context.resumeBackgroundListener();
      return;
    }

    if (_sessionClosing) return;
    _sessionClosing = true;

    _context.logger.info('SttCommandRecognizer: closing session', {
      'reason': reason,
      'bestTranscript': _bestTranscript,
      'commandHandled': _commandHandled,
    });

    _cancelTimers();
    await _speech.stop();

    if (!_commandHandled) {
      final words = _bestTranscript.trim();
      if (words.isEmpty) {
        _context.notifier.notify(VoiceFeedback.noCommandDetected);
      } else {
        _context.notifier.notifyTranscript(words);
      }
    }

    _sessionActive = false;
    _sessionClosing = false;
    _commandHandled = false;
    _bestTranscript = '';

    await _context.resumeBackgroundListener();
  }

  void _closeSessionIfNeeded({required String reason}) {
    if (_commandHandled) return;
    unawaited(_closeSession(reason: reason));
  }

  void _cancelTimers() {
    _sessionTimeoutTimer?.cancel();
    _sessionTimeoutTimer = null;

    _closeAfterStatusTimer?.cancel();
    _closeAfterStatusTimer = null;
  }
}
