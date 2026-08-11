/// On-device wake-word detection and voice-command recognition.
///
/// The package owns the whole audio path — microphone capture, wake-word
/// inference and command recognition — and knows nothing about the app that
/// hosts it. A consumer describes *what* to listen for (models and phrases)
/// and *what to do* about it (a callback); everything in between is here.
///
/// See `README.md` for a worked example.
library;

export 'src/audio/wake_word_audio_channel.dart' show WakeWordAudioChannel;
export 'src/config/model_source.dart';
export 'src/config/voice_command.dart';
export 'src/config/voice_pipeline_config.dart';
export 'src/config/wake_word_model.dart';
export 'src/engine/model_resolver.dart' show ModelResolver;
export 'src/engine/wake_word_engine.dart'
    show ModelLoadFailure, WakeWordDetection, WakeWordEngine;
export 'src/listener/wake_word_capture.dart' show WakeWordCapture;
export 'src/listener/wake_word_listener.dart' show WakeWordListener;
export 'src/pipeline/voice_pipeline.dart' show VoicePipeline;
export 'src/platform/voice_logger.dart';
export 'src/platform/voice_notifier.dart';
export 'src/recognition/command_recognizer.dart';
export 'src/recognition/model_command_recognizer.dart'
    show ModelCommandRecognizer;
export 'src/recognition/speech_recognizer.dart';
export 'src/recognition/stt_command_recognizer.dart' show SttCommandRecognizer;
