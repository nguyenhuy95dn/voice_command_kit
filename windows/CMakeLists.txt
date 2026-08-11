# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "voice_command_kit")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "voice_command_kit_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "voice_command_kit_plugin.cpp"
  "voice_command_kit_plugin.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/voice_command_kit/voice_command_kit_plugin_c_api.h"
  "voice_command_kit_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
# Belt-and-suspenders alongside the #define NOMINMAX in the plugin's own
# sources: a compiler flag applies before any file is preprocessed, so it
# can't lose a race with whichever header happens to include <windows.h>
# first (Flutter's own headers do, ahead of this plugin's own).
target_compile_definitions(${PLUGIN_NAME} PRIVATE NOMINMAX)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
# WASAPI capture.
target_link_libraries(${PLUGIN_NAME} PRIVATE ole32 mmdevapi)

# ===========================================================================
# Wake-word inference engine
#
# A second, standalone DLL: Dart loads it directly with DynamicLibrary.open,
# so it deliberately is *not* linked into the plugin DLL above. Unlike the
# Apple platforms — where the core is statically linked into the host binary
# and reached through DynamicLibrary.process() — Windows keeps it separate and
# ships it next to the executable.
# ===========================================================================

set(VOICE_WAKEWORD_CORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../src")
set(VOICE_WAKEWORD_ONNXRUNTIME_DIR "${CMAKE_CURRENT_SOURCE_DIR}/onnxruntime")

if(NOT EXISTS "${VOICE_WAKEWORD_ONNXRUNTIME_DIR}/lib/onnxruntime.lib")
  message(FATAL_ERROR
    "ONNX Runtime for Windows is missing. Expected onnxruntime.lib and "
    "onnxruntime.dll under ${VOICE_WAKEWORD_ONNXRUNTIME_DIR}/lib — see the "
    "package README.")
endif()

add_library(voice_wakeword SHARED
  "${VOICE_WAKEWORD_CORE_DIR}/voice_wakeword.cpp"
)

target_compile_definitions(voice_wakeword PRIVATE VOICE_WAKEWORD_BUILD_DLL)

set_target_properties(voice_wakeword PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON)

target_include_directories(voice_wakeword PRIVATE
  "${VOICE_WAKEWORD_CORE_DIR}/include"
  "${VOICE_WAKEWORD_ONNXRUNTIME_DIR}/include")

target_link_libraries(voice_wakeword PRIVATE
  "${VOICE_WAKEWORD_ONNXRUNTIME_DIR}/lib/onnxruntime.lib")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(voice_command_kit_bundled_libraries
  "$<TARGET_FILE:voice_wakeword>"
  "${VOICE_WAKEWORD_ONNXRUNTIME_DIR}/lib/onnxruntime.dll"
  PARENT_SCOPE
)
