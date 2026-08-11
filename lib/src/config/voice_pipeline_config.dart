import '../recognition/command_recognizer.dart';
import 'voice_command.dart';
import 'wake_word_model.dart';

/// Everything the pipeline needs to know about *what* to listen for.
///
/// Deliberately data only: no callbacks, no platform objects, so a consumer can
/// declare it once as a constant next to its other configuration.
final class VoicePipelineConfig {
  const VoicePipelineConfig({
    required this.features,
    required this.wakeWord,
    required this.commands,
    this.mode = CommandRecognitionMode.auto,
    this.locale = 'en_US',
    this.detectionCooldown = const Duration(milliseconds: 1500),
    this.commandSessionTimeout = const Duration(seconds: 7),
    this.speechSessionTimeout = const Duration(seconds: 8),
    this.speechListenFor = const Duration(seconds: 6),
    this.speechPauseFor = const Duration(seconds: 5),
    this.healthCheckInterval = const Duration(seconds: 10),
  });

  /// The generic mel and embedding models shared by every phrase.
  final FeatureModels features;

  /// The phrase that opens a command session, e.g. "Hey Motion Future".
  final WakeWordModel wakeWord;

  /// What can be said once the wake word has fired.
  final List<VoiceCommand> commands;

  final CommandRecognitionMode mode;

  /// Locale for speech-to-text. Should match the language
  /// [VoiceCommand.phrases] are written in, which is not necessarily the
  /// device's locale.
  final String locale;

  /// How long detections are suppressed after one fires, so a single spoken
  /// phrase reports once rather than once per frame.
  final Duration detectionCooldown;

  /// How long an offline command session waits for a command.
  final Duration commandSessionTimeout;

  /// Hard ceiling on a speech-to-text session, independent of what the engine
  /// itself reports.
  final Duration speechSessionTimeout;

  /// How long speech-to-text listens in total.
  final Duration speechListenFor;

  /// How long a silence ends a speech-to-text session.
  final Duration speechPauseFor;

  /// How often the watchdog checks that capture is alive, and retries a start
  /// that previously failed — plugging in a microphone later is picked up here.
  final Duration healthCheckInterval;
}
