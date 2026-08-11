# onnxruntime.framework (macOS)

The macOS pod links **ONNX Runtime 1.26.0** the same way iOS does: a vendored,
static `onnxruntime.framework` sitting next to this README. It is **committed to
the repo**, same as the iOS framework (`ios/Frameworks/onnxruntime.framework`),
the Windows binaries (`windows/onnxruntime/`) and the Android shared objects
(`android/src/main/cpp/onnxruntime/`).

`voice_command_kit.podspec` declares
`spec.vendored_frameworks = 'Frameworks/onnxruntime.framework'` and adds
`Frameworks/onnxruntime.framework/Headers` to its header search paths, so the
shared C++ source's `#include "onnxruntime_c_api.h"` resolves. Because it is a
**static** framework it links straight into the host executable — no embedding
or extra code-signing, just like iOS. That is also what lets Dart find the
`wake_word_*` symbols through `DynamicLibrary.process()`.

## Provenance (how this exact binary was produced)

- Version **1.26.0** (`ORT_API_VERSION 26`), matching iOS/Windows.
- Architecture: **universal2 (x86_64 + arm64)**. `MinimumOSVersion` in the
  framework's `Resources/Info.plist` is 14.0; harmless when statically linked
  into the 13.0 host target (it may emit a "built for newer macOS" link note).
- Source: Microsoft's official pod archive
  `https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.26.0.zip`
  (the `onnxruntime-c` 1.26.0 CocoaPods distribution — the same archive iOS's
  framework came from).
- Extraction: unzip, then copy the
  `onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework` slice here
  verbatim (preserving the `Versions/` symlinks, e.g. with `ditto`).

## After adding / updating it

Re-run `cd macos && pod install` so CocoaPods picks up the vendored framework and
its header search paths, then rebuild.
