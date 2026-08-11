cmake_minimum_required(VERSION 3.22.1)

project(voice_wakeword)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# packages/voice_command_kit/src — the C++ core shared with iOS, macOS and Windows.
set(VOICE_WAKEWORD_CORE_DIR ${CMAKE_CURRENT_LIST_DIR}/../../../../src)
set(VOICE_WAKEWORD_ONNXRUNTIME_DIR ${CMAKE_CURRENT_LIST_DIR}/onnxruntime)

if(NOT EXISTS ${VOICE_WAKEWORD_ONNXRUNTIME_DIR}/include/onnxruntime_c_api.h)
    message(FATAL_ERROR
        "ONNX Runtime headers are missing. Expected them under "
        "${VOICE_WAKEWORD_ONNXRUNTIME_DIR}/include — see the package README.")
endif()

add_library(voice_wakeword SHARED
    ${VOICE_WAKEWORD_CORE_DIR}/voice_wakeword.cpp
)

target_link_options(voice_wakeword PRIVATE
    "-Wl,-z,max-page-size=16384"
)

add_library(onnxruntime SHARED IMPORTED)

set_target_properties(onnxruntime PROPERTIES
    IMPORTED_LOCATION
    ${VOICE_WAKEWORD_ONNXRUNTIME_DIR}/lib/${ANDROID_ABI}/libonnxruntime.so
)

target_include_directories(voice_wakeword PRIVATE
    ${VOICE_WAKEWORD_CORE_DIR}/include
    ${VOICE_WAKEWORD_ONNXRUNTIME_DIR}/include
)

target_link_libraries(voice_wakeword
    onnxruntime
    log
)
