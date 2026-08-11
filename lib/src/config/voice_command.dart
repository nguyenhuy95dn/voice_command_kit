import 'model_source.dart';
import 'wake_word_model.dart';

/// Something the user can ask for once the wake word has fired.
///
/// A command can carry [phrases], a [classifier], or both — which one is used
/// depends on how the command is recognised at the time:
///
/// - speech-to-text matches the transcript against [phrases];
/// - fully offline recognition listens for [classifier], a model trained on
///   this phrase.
///
/// Supplying both lets one configuration serve platforms that have usable
/// speech-to-text and platforms that do not, and lets a single platform fall
/// back when the microphone is otherwise occupied.
final class VoiceCommand {
  const VoiceCommand({
    required this.id,
    this.phrases = const [],
    this.classifier,
    this.threshold = 0.2,
  });

  /// Whether anything could ever recognise this command. Checked by the
  /// pipeline rather than asserted in the constructor, so a configuration can
  /// still be declared `const`.
  bool get isRecognisable => phrases.isNotEmpty || classifier != null;

  /// How the consumer refers to this command. Passed back to the command
  /// callback, and the value `availableCommands` returns. Opaque to the
  /// package.
  final String id;

  /// Transcript fragments that mean this command, lower-case. A transcript
  /// matches when it *contains* one of them, so short, distinctive fragments
  /// work better than whole sentences.
  final List<String> phrases;

  /// A model trained to detect this phrase directly from audio.
  final ModelSource? classifier;

  /// Detection threshold for [classifier]. Ignored without one.
  final double threshold;

  /// The engine-level model for this command, or `null` when it is
  /// speech-to-text only.
  WakeWordModel? get wakeWordModel {
    final classifier = this.classifier;
    if (classifier == null) return null;
    return WakeWordModel(id: id, classifier: classifier, threshold: threshold);
  }

  @override
  String toString() => 'VoiceCommand($id)';
}
