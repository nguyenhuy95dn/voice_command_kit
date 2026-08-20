## 1.0.3

- Fixed a second, unrelated fatal `EXC_BAD_INSTRUCTION` crash on macOS —
  this one on genuinely native arm64 (no Rosetta): ONNX Runtime's MLAS
  KleidiAI backend feature-detects ARM SME as available on Apple Silicon
  and dispatches an SME GEMM kernel (`kai_run_lhs_pack_f32p2vlx1_f32_sme`)
  that traps, since the process has no real usable SME execution state.
  `wake_word_init` now sets the documented `mlas.disable_kleidiai` session
  option to force MLAS back onto its non-SME kernels.

## 1.0.2

- Fixed a fatal `EXC_BAD_INSTRUCTION` crash on macOS the first time the wake
  word engine ran inference while the app was running under Rosetta 2
  translation (e.g. Xcode's "My Mac (Rosetta)" run destination on Apple
  Silicon): the x86_64 slice of `onnxruntime.framework` uses AVX2/FMA
  instructions Rosetta does not reliably translate. `wake_word_init` now
  detects translation via `sysctlbyname` and fails cleanly before touching
  ONNX Runtime, the same as every other init-failure guard — voice control
  just doesn't start instead of crashing the process. Native Apple Silicon
  (no Rosetta) is unaffected.

## 1.0.1

- Fixed a fatal `MissingPluginException` crash on Android/iOS/Windows: the
  device-events channel is now only listened to on macOS, the only platform
  that implements it. Previously, `EventChannel.receiveBroadcastStream()`'s
  internal `listen` call failed via `FlutterError.reportError` on every other
  platform — a failure mode a stream's `onError` cannot catch — so it reached
  crash reporting instead of being silently ignored as intended.

## 1.0.0

- First stable release. API surface (`VoicePipeline`, `VoicePipelineConfig`,
  `WakeWordModel`, `VoiceCommand`, `ModelSource`) considered stable for
  Android, iOS, macOS and Windows.
- Documented environment/toolchain requirements in `CLAUDE.md`: Dart
  `>=3.8.0 <4.0.0`, Flutter `>=3.24.0`, Android (Kotlin 2.2.20, AGP 8.11.1,
  compileSdk 36, minSdk 24, NDK 27.0.12077973), iOS 15.0 / Swift 5.0,
  macOS 13.0 / Swift 5.0, Windows CMake >=3.14 / C++17.

## 0.1.0

- Initial extraction from the Poscura app: wake-word engine, audio capture for
  Android/iOS/macOS/Windows, speech-to-text and wake-word-model command
  recognizers, and the pipeline that ties them together.
