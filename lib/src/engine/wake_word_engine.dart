import 'dart:typed_data';

import '../config/model_source.dart';
import '../config/wake_word_model.dart';
import '../util/async_lock.dart';
import 'model_resolver.dart';
import 'wake_word_bindings.dart';

/// Thrown by [WakeWordEngine.init] when one or more configured models could
/// not be resolved — see [ModelResolver.resolve] for what counts as a
/// failure there.
///
/// Distinct from whatever else [init] might throw (a native failure, say)
/// because this one is permanent: nothing about retrying changes until the
/// configuration itself does. A host that wants to tell the two apart —
/// keep silently retrying vs. give up and surface it — catches this type
/// specifically. See [WakeWordListener]'s `onEngineInitFailed`.
final class ModelLoadFailure implements Exception {
  const ModelLoadFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A phrase the engine recognised in the audio it was fed.
final class WakeWordDetection {
  const WakeWordDetection({required this.modelId, required this.score});

  /// [WakeWordModel.id] of the model that fired.
  final String modelId;

  /// The winning model's score, at or above its threshold.
  final double score;

  @override
  String toString() =>
      'WakeWordDetection($modelId, score: ${score.toStringAsFixed(3)})';
}

/// Runs wake-word inference over 16 kHz mono Int16 PCM.
///
/// Every model in [models] is loaded natively up front, because loading is slow
/// and a command session has to switch phrases mid-stream. Which of them can
/// actually fire is then a cheap in-memory choice — see [setActive].
final class WakeWordEngine {
  WakeWordEngine({
    required FeatureModels features,
    required List<WakeWordModel> models,
    this.cooldown = const Duration(milliseconds: 1500),
    ModelResolver? modelResolver,
  }) : _features = features,
       _models = List.unmodifiable(models),
       _resolver = modelResolver ?? ModelResolver() {
    if (_models.isEmpty) {
      throw ArgumentError.value(models, 'models', 'must not be empty');
    }

    final ids = <String>{};
    for (final model in _models) {
      if (!ids.add(model.id)) {
        throw ArgumentError.value(
          models,
          'models',
          'duplicate model id "${model.id}"',
        );
      }
    }
  }

  final FeatureModels _features;
  final List<WakeWordModel> _models;
  final ModelResolver _resolver;
  final _lock = AsyncLock();

  /// How long detections are suppressed after one fires. Without it a single
  /// spoken phrase, which spans many frames, reports several times.
  final Duration cooldown;

  bool _initialized = false;
  List<WakeWordModel> _active = const [];
  DateTime? _lastDetectedAt;

  /// The models this engine knows about, in the order their scores arrive from
  /// native code.
  List<WakeWordModel> get models => _models;

  Future<void> init() => _lock.run(_initInternal);

  /// Every model — the shared features and every classifier — is resolved and
  /// checked to exist before any of it reaches native code. `wake_word_init`
  /// loads the whole set in one call, so one missing file would otherwise fail
  /// the wake word too, not just the command it belongs to; resolving all of
  /// them first, and reporting every failure together rather than stopping at
  /// the first, turns that into one clear error instead of an opaque native
  /// failure (or, worse, a silent one — see [WakeWordListener]'s health check,
  /// which retries a failed [init] indefinitely without this).
  Future<void> _initInternal() async {
    if (_initialized) return;

    final labels = <String>[
      'mel spectrogram',
      'embedding',
      for (final model in _models) model.id,
    ];
    final sources = <ModelSource>[
      _features.melSpectrogram,
      _features.embedding,
      for (final model in _models) model.classifier,
    ];

    final paths = <String>[];
    final failures = <String>[];
    for (var i = 0; i < sources.length; i++) {
      try {
        paths.add(await _resolver.resolve(sources[i], label: labels[i]));
      } on Object catch (error) {
        failures.add(error.toString());
      }
    }

    if (failures.isNotEmpty) {
      throw ModelLoadFailure(
        'Wake word engine could not load ${failures.length} of '
        '${sources.length} model(s):\n'
        '${failures.map((f) => '  - $f').join('\n')}',
      );
    }

    WakeWordBindings.init(
      melModelPath: paths[0],
      embeddingModelPath: paths[1],
      classifierModelPaths: paths.sublist(2),
    );

    _initialized = true;

    // setActive is only forwarded to native while _initialized is true, so a
    // call that raced ahead of init (set _active here but had nothing to tell
    // native yet) would otherwise leave native defaulting to "everything
    // active" until the next setActive call. Sync once now to close that gap.
    if (_active.isNotEmpty) {
      _syncActiveToNative();
    }
  }

  /// Restricts detection to [modelIds]. Ids that are not loaded are ignored, so
  /// a caller can pass a superset without checking first.
  ///
  /// Cheap enough to call between PCM chunks: nothing is loaded or unloaded —
  /// but it does tell native to stop running inference for models that
  /// dropped out, which is where the actual CPU cost was going.
  void setActive(Iterable<String> modelIds) {
    final wanted = modelIds.toSet();
    _active = _models.where((model) => wanted.contains(model.id)).toList();
    if (_initialized) {
      _syncActiveToNative();
    }
  }

  void _syncActiveToNative() {
    WakeWordBindings.setActive([
      for (final model in _active) _models.indexOf(model),
    ]);
  }

  /// Feeds one chunk of 16 kHz mono Int16 PCM.
  ///
  /// Returns the highest-scoring active model that cleared its threshold, or
  /// `null` when nothing fired — including while in [cooldown].
  WakeWordDetection? processPcm(Int16List pcm) {
    if (!_initialized || _active.isEmpty) return null;

    // Scores come back for every loaded model, indexed by load order.
    // Audio PCM is always fed to native code so the feature ring buffers
    // continuously advance with real-time audio even during cooldown.
    final scores = WakeWordBindings.processPcm(pcm, _models.length);
    if (scores.isEmpty) {
      throw StateError('Wake word native error: ${WakeWordBindings.lastError()}');
    }

    final now = DateTime.now();
    final lastDetectedAt = _lastDetectedAt;
    if (lastDetectedAt != null && now.difference(lastDetectedAt) < cooldown) {
      return null;
    }

    WakeWordModel? best;
    double bestScore = 0;

    for (final model in _active) {
      final index = _models.indexOf(model);
      if (index < 0 || index >= scores.length) continue;

      final score = scores[index];
      if (score >= model.threshold && score > bestScore) {
        best = model;
        bestScore = score;
      }
    }

    if (best == null) return null;

    _lastDetectedAt = now;
    return WakeWordDetection(modelId: best.id, score: bestScore);
  }

  /// Clears the engine's audio history, so the next chunk starts a fresh
  /// window. Called when capture stops and restarts.
  void reset() {
    if (_initialized) {
      WakeWordBindings.reset();
    }
    _lastDetectedAt = null;
  }

  Future<void> dispose() => _lock.run(_disposeInternal);

  Future<void> _disposeInternal() async {
    if (!_initialized) return;
    WakeWordBindings.close();
    _initialized = false;
    _active = const [];
    _lastDetectedAt = null;
  }
}
