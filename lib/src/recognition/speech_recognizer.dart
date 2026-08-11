import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// A transcript, partial or final.
final class SpeechResult {
  const SpeechResult({required this.transcript, required this.isFinal});

  final String transcript;
  final bool isFinal;
}

/// Something went wrong mid-recognition.
final class SpeechError {
  const SpeechError({required this.code, this.permanent = false});

  /// Engine-defined. Two codes carry meaning to this package, both from the
  /// `speech_to_text` vocabulary: `error_no_match` (heard nothing usable —
  /// ignored, the session runs to its own timeout) and `error_speech_timeout`
  /// (the user stopped talking — closes the session). Any other code closes the
  /// session as a failure. An alternative engine should mirror those two names
  /// to behave the same.
  final String code;

  /// Whether the engine considers this unrecoverable.
  final bool permanent;
}

/// Speech-to-text, abstracted so it can be swapped.
///
/// The package ships [SpeechToTextRecognizer] on top of the `speech_to_text`
/// plugin, which is the right default on Android, iOS and macOS. A consumer
/// that needs an on-device model, a cloud service, or a language the platform
/// engine lacks implements this instead.
abstract interface class SpeechRecognizer {
  /// Prepares the engine. Returns whether it is usable at all on this device.
  /// Called once, lazily, on the first session.
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(SpeechError error) onError,
  });

  /// Starts a listening session. Returns as soon as listening has begun;
  /// transcripts arrive on [onResult].
  Future<void> listen({
    required void Function(SpeechResult result) onResult,
    required String localeId,
    required Duration listenFor,
    required Duration pauseFor,
  });

  Future<void> stop();

  bool get isListening;
}

/// [SpeechRecognizer] backed by the `speech_to_text` plugin.
final class SpeechToTextRecognizer implements SpeechRecognizer {
  SpeechToTextRecognizer({SpeechToText? speechToText})
    : _speechToText = speechToText ?? SpeechToText();

  final SpeechToText _speechToText;

  @override
  bool get isListening => _speechToText.isListening;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(SpeechError error) onError,
  }) {
    return _speechToText.initialize(
      onStatus: onStatus,
      onError: (SpeechRecognitionError error) => onError(
        SpeechError(code: error.errorMsg, permanent: error.permanent),
      ),
    );
  }

  @override
  Future<void> listen({
    required void Function(SpeechResult result) onResult,
    required String localeId,
    required Duration listenFor,
    required Duration pauseFor,
  }) {
    return _speechToText.listen(
      onResult: (SpeechRecognitionResult result) => onResult(
        SpeechResult(
          transcript: result.recognizedWords,
          isFinal: result.finalResult,
        ),
      ),
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        listenFor: listenFor,
        pauseFor: pauseFor,
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  @override
  Future<void> stop() async {
    if (_speechToText.isListening) {
      await _speechToText.stop();
    }
  }
}
