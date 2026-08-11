import 'model_source.dart';

/// The two models every wake word shares.
///
/// They are the generic front half of the openWakeWord topology — audio to mel
/// frames, mel frames to embeddings — and carry no knowledge of any particular
/// phrase, so one pair serves every [WakeWordModel] in a configuration.
final class FeatureModels {
  const FeatureModels({required this.melSpectrogram, required this.embedding});

  final ModelSource melSpectrogram;
  final ModelSource embedding;
}

/// A single trained phrase the engine can detect.
///
/// [id] is how the consumer refers to this model — in `availableCommands`, in
/// the command callback, in logs. It is opaque to the package.
final class WakeWordModel {
  const WakeWordModel({
    required this.id,
    required this.classifier,
    this.threshold = 0.2,
  }) : assert(threshold > 0 && threshold <= 1, 'threshold must be in (0, 1]');

  final String id;

  /// The per-phrase classifier: embeddings in, score out.
  final ModelSource classifier;

  /// Score above which a frame counts as a detection. Higher trades recall for
  /// precision; tune per model, since it depends on how the model was trained.
  final double threshold;

  @override
  String toString() => 'WakeWordModel($id)';
}
