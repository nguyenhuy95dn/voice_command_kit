#ifndef FLUTTER_PLUGIN_VOICE_COMMAND_KIT_PLUGIN_H_
#define FLUTTER_PLUGIN_VOICE_COMMAND_KIT_PLUGIN_H_

// Must come before any Windows/Flutter header below — audioclient.h and
// mmdeviceapi.h pull in <windows.h>, whose min/max macros otherwise mangle
// std::min/std::max/std::clamp in voice_command_kit_plugin.cpp into invalid
// syntax (MSVC C2589/C2059/C2062). #undef as a second line of defense in case
// something upstream of this header already included windows.h unguarded.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#undef min
#undef max

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

namespace voice_command_kit {

// Windows microphone capture for the wake word engine.
//
// Exposes the same channel contract as the Android, iOS and macOS plugins in
// this package:
//   MethodChannel "voice_command_kit/audio": startListening / stopListening /
//     isListening / checkOrRequestPermission
//   EventChannel  "voice_command_kit/pcm": raw mono 16 kHz Int16 PCM chunks
class VoiceCommandKitPlugin : public flutter::Plugin {
 public:
  // Registers the plugin with the engine. The registrar takes ownership, so
  // capture is torn down by the destructor when the engine goes away — there is
  // no separate shutdown call for the host app to remember.
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit VoiceCommandKitPlugin(flutter::BinaryMessenger* messenger);
  ~VoiceCommandKitPlugin() override;

  VoiceCommandKitPlugin(const VoiceCommandKitPlugin&) = delete;
  VoiceCommandKitPlugin& operator=(const VoiceCommandKitPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void StartListening(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopListeningInternal();
  bool ProbeMicrophoneAccess();

  void CaptureThreadMain(
      std::shared_ptr<std::promise<std::pair<bool, std::string>>> init_signal);

  void EmitPcm(const int16_t* samples, size_t count);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;

  std::mutex sink_mutex_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  std::atomic<bool> running_{false};
  std::thread capture_thread_;

  flutter::BinaryMessenger* messenger_;
};

}  // namespace voice_command_kit

#endif  // FLUTTER_PLUGIN_VOICE_COMMAND_KIT_PLUGIN_H_
