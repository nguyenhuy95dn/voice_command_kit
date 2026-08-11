//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <speech_to_text_windows/speech_to_text_windows.h>
#include <voice_command_kit/voice_command_kit_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  SpeechToTextWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("SpeechToTextWindows"));
  VoiceCommandKitPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("VoiceCommandKitPluginCApi"));
}
