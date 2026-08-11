/// The slice of capture control a command recognizer is allowed to use.
///
/// Recognizers start and stop listening and swap which models may fire; they
/// have no business with engine lifecycle or health reporting, so those stay
/// off this interface. Being an interface also lets a recognizer be tested
/// without a microphone.
abstract interface class WakeWordCapture {
  /// Starts capture with [modelIds] eligible to fire, or — when capture is
  /// already running — swaps the active models in place.
  Future<bool> start({required List<String> modelIds});

  Future<void> stop();
}
