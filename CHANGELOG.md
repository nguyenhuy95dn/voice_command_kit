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
