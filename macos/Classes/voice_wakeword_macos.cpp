// macOS wake word runtime.
//
// Compiles the single canonical implementation shared with Android, iOS and
// Windows. macOS has no simulator slice, so (unlike the iOS wrapper) this simply
// pulls in the real implementation directly. ONNX Runtime headers are found via
// the podspec's HEADER_SEARCH_PATHS (Frameworks/onnxruntime.framework/Headers).
#include "../../src/voice_wakeword.cpp"
