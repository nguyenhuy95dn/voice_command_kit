import '../config/voice_command.dart';
import '../engine/wake_word_engine.dart';
import '../listener/wake_word_capture.dart';
import '../platform/voice_logger.dart';
import '../platform/voice_notifier.dart';

/// How a spoken command is recognised once the wake word has fired.
enum CommandRecognitionMode {
  /// The wake word hands the microphone to speech-to-text and the command is
  /// matched from a free-form transcript.
  speechToText,

  /// The command is detected by a dedicated model, fully offline. The only
  /// option where speech-to-text is unavailable or unreliable.
  wakeWordModel,

  /// Speech-to-text where the platform supports it, models elsewhere. Windows
  /// has no usable speech-to-text, so it gets models; everything else gets
  /// speech-to-text.
  auto,
}

/// What a recognizer needs from the pipeline that hosts it.
///
/// Recognizers depend on this narrow surface rather than on the pipeline's
/// internals, so the two recognition mechanisms stay isolated from each other
/// and from the lifecycle and watchdog code.
abstract interface class VoiceRecognizerContext {
  /// Capture, including the in-place model swap a command session needs.
  WakeWordCapture get listener;

  VoiceLogger get logger;

  VoiceNotifier get notifier;

  /// Whether the pipeline has been disposed.
  bool get isDisposed;

  /// [id] of the wake-word model that opens a command session.
  String get wakeWordId;

  /// Every configured command, whether or not it is currently offered.
  List<VoiceCommand> get commands;

  /// Ids of the commands that make sense right now. The host narrows this by
  /// whatever state it cares about — the visible screen, what is already
  /// running — and the package never second-guesses it.
  List<String> availableCommandIds();

  /// Whether speech-to-text can be started at this moment. False when
  /// something else holds the microphone, in which case a
  /// [CommandRecognitionMode.speechToText] session falls back to models.
  bool canUseSpeechToText();

  /// Runs a recognised command. Returns whether the host actually did it.
  Future<bool> dispatch(String commandId);

  /// Restores background wake-word listening after a session. No-ops when the
  /// pipeline is stopped or disposed.
  Future<void> resumeBackgroundListener();
}

/// Turns detections into executed commands for one recognition mechanism.
abstract interface class CommandRecognizer {
  /// Handles a detection: the wake word that opens a session, and any command
  /// detection within it.
  Future<void> handleDetection(WakeWordDetection detection);

  /// Whether a command session is in progress. Gates the pipeline watchdog so
  /// it does not fight an in-flight session.
  bool get hasActiveSession;

  /// Abandons any session in progress. [resumeListener] is true when the caller
  /// wants background listening restored, false when the pipeline is stopping
  /// entirely.
  Future<void> abortSession({required bool resumeListener});

  /// Releases timers and engines. Does not resume listening.
  Future<void> dispose();
}
