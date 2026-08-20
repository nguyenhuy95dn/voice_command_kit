// Pigeon schema for the `voice_command_kit/audio` method-channel contract.
//
// Regenerate with `tool/generate_pigeons.sh` after editing this file. Only
// the request/response calls live here — the PCM and device-event streams
// stay hand-written `EventChannel`s on every platform because Pigeon's
// typed-streaming generator (`@EventChannelApi`) does not target C++, and
// this package must keep an identical contract on Windows.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/audio/messages.g.dart',
    kotlinOut:
        'android/src/main/kotlin/com/nightsoft/voice_command_kit/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.nightsoft.voice_command_kit'),
    // swiftOut is intentionally omitted: iOS and macOS each need their own
    // copy under Classes/, so tool/generate_pigeons.sh passes --swift_out
    // twice on the command line instead of relying on one default here.
    cppHeaderOut: 'windows/messages.g.h',
    cppSourceOut: 'windows/messages.g.cpp',
    cppOptions: CppOptions(namespace: 'voice_command_kit'),
  ),
)
@HostApi()
abstract class WakeWordAudioHostApi {
  /// Returns whether the microphone may be used, prompting the user if that
  /// question has not been answered yet.
  @async
  bool checkOrRequestPermission();

  @async
  void startListening();

  @async
  void stopListening();

  @async
  bool isListening();
}
