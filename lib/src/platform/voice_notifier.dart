/// A moment in a command session the user should be told about.
///
/// Deliberately an enum rather than a message: the package has no business
/// choosing wording or a language for someone else's app. A consumer maps these
/// to its own localized strings and its own presentation — a toast, a chime, an
/// overlay, or nothing at all.
enum VoiceFeedback {
  /// The wake word fired; the user is expected to speak a command now.
  listening,

  /// The session ended without recognising a command.
  noCommandDetected,

  /// A command was recognised but the host declined to run it.
  commandUnavailable,

  /// Speech-to-text could not be started on this device.
  speechUnavailable,
}

/// Where user-facing feedback goes.
abstract interface class VoiceNotifier {
  void notify(VoiceFeedback feedback);

  /// Speech that was recognised but matched no command. Only reached in
  /// speech-to-text mode, and worth surfacing: it is what tells a user their
  /// phrasing was heard but not understood.
  void notifyTranscript(String transcript);
}

/// Reports nothing. The default, for a consumer that drives its own UI from the
/// pipeline's callbacks instead.
final class SilentVoiceNotifier implements VoiceNotifier {
  const SilentVoiceNotifier();

  @override
  void notify(VoiceFeedback feedback) {}

  @override
  void notifyTranscript(String transcript) {}
}
