// Must come before any include that might pull in <windows.h> (Flutter's own
// headers do) — its min/max macros otherwise mangle std::min/std::max/std::clamp
// calls in voice_command_kit_plugin.cpp into invalid syntax (MSVC C2589/C2059/C2062).
// Guarded: the CMake target already defines this on the command line (see
// windows/CMakeLists.txt), so an unconditional #define here would redefine it —
// C4005, fatal under this project's warnings-as-errors (C2220).
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "include/voice_command_kit/voice_command_kit_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "voice_command_kit_plugin.h"

void VoiceCommandKitPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  voice_command_kit::VoiceCommandKitPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
