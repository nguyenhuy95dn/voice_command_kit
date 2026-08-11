// iOS wake word runtime.
//
// On device this compiles the single canonical implementation shared with
// Android, macOS and Windows. ONNX Runtime headers are found via the podspec's
// HEADER_SEARCH_PATHS (Frameworks/onnxruntime.framework/Headers).
//
// The simulator has no ONNX Runtime slice, so it gets a stub instead: the
// wake_word_* symbols still exist (Dart looks them up unconditionally through
// DynamicLibrary.process()) but report that inference is unavailable rather
// than failing to link.

#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR

#include <cstdint>

#include "../../src/include/voice_wakeword.h"

namespace {

constexpr const char* kSimulatorError =
    "Wake word inference is not supported on the iOS Simulator";

}  // namespace

extern "C" {

int wake_word_init(
    const char*,
    const char*,
    const char**,
    int
) {
    return 0;
}

int wake_word_process_pcm(const short*, int, float*, int) {
    return -1;
}

void wake_word_reset() {}

void wake_word_close() {}

const char* wake_word_last_error() {
    return kSimulatorError;
}

__attribute__((used))
static void* const g_simulator_forced_symbols[] = {
    (void*)&wake_word_init,
    (void*)&wake_word_process_pcm,
    (void*)&wake_word_reset,
    (void*)&wake_word_close,
    (void*)&wake_word_last_error,
};

volatile int g_simulator_forced_link_dummy = 0;

void voice_wakeword_force_link() {
    g_simulator_forced_link_dummy =
        (int)reinterpret_cast<intptr_t>(g_simulator_forced_symbols);
}

}  // extern "C"

#else

#include "../../src/voice_wakeword.cpp"

#endif
