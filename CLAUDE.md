# voice_command_kit — Repo Context

Flutter plugin: on-device wake-word detection + voice-command recognition
(Android, iOS, macOS, Windows). Native audio capture + ONNX inference, glued
by a Dart pipeline (`VoicePipeline`) with pluggable speech-to-text / model
classifiers.

## Environment / SDK requirements

| Component | Version |
|---|---|
| Flutter SDK (actually in use) | `3.41.9`, stable channel — matches `.metadata` revision `00b0c91f06` exactly |
| Dart SDK (actually in use) | `3.11.5` |
| Flutter SDK constraint | `>=3.24.0` (pubspec.yaml) |
| Dart SDK constraint | `>=3.8.0 <4.0.0` (pubspec.yaml) |
| Project type | `plugin` (federated: android/ios/macos/windows) |

> Note: plain `flutter`/`dart` are not on PATH in a bare shell — this machine
> manages SDKs via `fvm` (global default `3.41.9`). No `.fvmrc` is committed to
> the repo by choice; the README states the plain Flutter/Dart version instead.

### Android
- Kotlin: `2.2.20`
- AGP (com.android.tools.build:gradle): `8.11.1`
- compileSdk: `36`, minSdk: `24`
- NDK: `27.0.12077973`, CMake: `3.22.1`
- Java source/target compatibility: `17`
- namespace: `com.nightsoft.voice_command_kit`

### iOS
- Deployment target: `15.0`
- Swift: `5.0`

### macOS
- Deployment target: `13.0`
- Swift: `5.0`

### Windows
- CMake: `>=3.14`
- C++ standard: `17`

## Host machine (for reference)
- macOS `26.6` (build 25G72), Darwin kernel `25.6.0`, arm64 (Apple Silicon)

## Key dependencies (pubspec.yaml)
- `ffi: ^2.2.0`
- `path_provider: ^2.1.5`
- `speech_to_text: ^7.4.0`
- dev: `flutter_lints: ^6.0.0`

## Docs in repo
- [README.md](README.md) — usage / pipeline overview
- [NATIVE.md](NATIVE.md) — native integration details
- [doc/ONNX_RUNTIME_IOS_CUSTOM_BUILD.md](doc/ONNX_RUNTIME_IOS_CUSTOM_BUILD.md)
- [doc/TRAINING_MODELS.md](doc/TRAINING_MODELS.md)
- [CHANGELOG.md](CHANGELOG.md)
