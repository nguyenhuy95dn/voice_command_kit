# Custom ONNX Runtime iOS Build Guide

## Purpose

This document explains how to rebuild the custom ONNX Runtime iOS framework this package vendors at `ios/Frameworks/onnxruntime.framework`.

The custom build is needed because the normal ONNX Runtime iOS framework can conflict with MediaPipe Tasks on iOS.

Previous linker issue:

```text
MediaPipeTasksCommon_device_graph.a
vs
onnxruntime.framework

duplicate symbols:
_xnn_*
_kai_*
```

Root cause:

```text
MediaPipeTasksCommon bundles XNNPACK / KleidiAI
ONNX Runtime also bundles XNNPACK / KleidiAI
```

So this custom build disables:

```text
XNNPACK
KleidiAI
```

and enables:

```text
CoreML
```

---

## Current Poscura Context

Android wakeword already uses:

```text
ONNX Runtime
melspectrogram.onnx
embedding_model.onnx
motion_future.onnx
```

iOS should reuse the same wakeword C/C++ pipeline and model files where possible.

Current iOS app also uses:

```ruby
pod 'MediaPipeTasksVision', '0.10.35'
```

Therefore, do not use the default ONNX Runtime iOS framework unless duplicate symbol issues are resolved.

---

## Prerequisites

Install required build tools:

```bash
brew install cmake
```

Verify:

```bash
which cmake
cmake --version
xcodebuild -version
```

Recommended:

```text
Xcode installed
Command Line Tools selected
CMake available in PATH
```

If needed:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

---

## Clone ONNX Runtime

```bash
cd /Users/huynguyen/Documents

git clone --recursive https://github.com/microsoft/onnxruntime.git
cd onnxruntime
```

Use the version matching Android if possible.

For example, if Android uses ONNX Runtime 1.26.0:

```bash
git checkout v1.26.0
git submodule update --init --recursive
```

If upgrading ONNX Runtime later, use the corresponding tag:

```bash
git fetch --tags
git checkout vX.Y.Z
git submodule update --init --recursive
```

---

## Build Command

Run from:

```bash
cd /Users/huynguyen/Documents/onnxruntime
```

Clean old build:

```bash
rm -rf build/iOS
```

Build custom iOS framework:

```bash
./build.sh \
  --config Release \
  --build_apple_framework \
  --ios \
  --apple_sysroot iphoneos \
  --apple_deploy_target 13.0 \
  --osx_arch arm64 \
  --cmake_generator Xcode \
  --skip_tests \
  --use_coreml \
  --no_kleidiai \
  --cmake_extra_defines \
    onnxruntime_USE_XNNPACK=OFF \
    CMAKE_POLICY_VERSION_MINIMUM=3.5
```

### Why these flags?

```text
--build_apple_framework
Builds Apple framework output.

--ios
Targets iOS.

--apple_sysroot iphoneos
Builds for physical iOS devices.

--osx_arch arm64
Builds arm64 device framework.

--cmake_generator Xcode
Required for Apple framework builds.

--use_coreml
Enables CoreML execution provider.

--no_kleidiai
Disables KleidiAI symbols that conflict with MediaPipe.

onnxruntime_USE_XNNPACK=OFF
Disables XNNPACK symbols that conflict with MediaPipe.

CMAKE_POLICY_VERSION_MINIMUM=3.5
Works around newer CMake rejecting older dependency CMakeLists.
```

---

## Expected Output

After build finishes, locate framework:

```bash
find build/iOS -name "*.xcframework" -o -name "*.framework"
```

Expected useful output:

```text
build/iOS/Release/Release-iphoneos/static_framework/onnxruntime.framework
```

This is the framework to use in Poscura.

---

## Copy Framework to Poscura

From Poscura project root:

```bash
cd /Users/huynguyen/Documents/FlutterResources/poscura-app

rm -rf packages/voice_command_kit/ios/Frameworks/onnxruntime.framework
rm -rf packages/voice_command_kit/ios/Frameworks/onnxruntime.xcframework

mkdir -p packages/voice_command_kit/ios/Frameworks

cp -R /Users/huynguyen/Documents/onnxruntime/build/iOS/Release/Release-iphoneos/static_framework/onnxruntime.framework \
  packages/voice_command_kit/ios/Frameworks/
```

---

## Podspec

The local pod should use:

```ruby
s.vendored_frameworks = 'Frameworks/onnxruntime.framework'
```

Do not use:

```ruby
s.vendored_frameworks = 'Frameworks/onnxruntime.xcframework'
```

unless the xcframework was also custom-built with XNNPACK/KleidiAI disabled.

Recommended podspec settings:

```ruby
Pod::Spec.new do |s|
  s.name             = 'voice_command_kit'
  s.version          = '0.1.0'
  s.summary          = 'Poscura wake word native runtime'
  s.description      = 'Native iOS wake word runtime using custom ONNX Runtime.'
  s.homepage         = 'https://poscura.local'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Poscura' => 'dev@poscura.local' }
  s.source           = { :path => '.' }

  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'

  s.source_files = [
    'Sources/**/*.{h,hh,hpp,c,cc,cpp,m,mm}'
  ]

  s.public_header_files = 'Sources/include/*.h'
  s.header_mappings_dir = 'Sources/include'

  s.vendored_frameworks = 'Frameworks/onnxruntime.framework'

  s.frameworks = [
    'Foundation',
    'Accelerate',
    'CoreML'
  ]

  s.libraries = [
    'c++',
    'z'
  ]

  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/Frameworks/onnxruntime.framework/Headers"'
  }
end
```

---

## Enable Pod in Podfile

Inside each app target:

```ruby
pod 'MediaPipeTasksVision', '0.10.35'
# (nothing to add — Flutter installs the plugin's pod automatically)
```

Example:

```ruby
targets = ['dev', 'prod', 'staging']

targets.each do |target_name|
  target target_name do
    use_frameworks!

    flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))

    pod 'MediaPipeTasksVision', '0.10.35'
    # (nothing to add — Flutter installs the plugin's pod automatically)
  end
end
```

---

## Clean and Reinstall Pods

From Poscura root:

```bash
cd /Users/huynguyen/Documents/FlutterResources/poscura-app

rm -rf build ios/build
rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*

cd ios
pod deintegrate
rm -rf Pods Podfile.lock
pod install
cd ..
```

---

## Build Poscura iOS

```bash
fvm flutter build ios \
  --flavor dev \
  -t lib/main/main_dev.dart \
  -v > ios_build.log 2>&1
```

---

## Verify Linker Issues

Search log:

```bash
grep -i -A 40 -B 20 "duplicate symbol\|xnn_\|kai_\|GTMSessionFetcher\|Linker command failed\|undefined symbol" ios_build.log
```

### Good result

No duplicate symbols involving:

```text
_xnn_*
_kai_*
onnxruntime.framework
MediaPipeTasksCommon
```

### Bad result: XNNPACK conflict remains

If log still shows:

```text
_xnn_...
MediaPipeTasksCommon
onnxruntime.framework
```

then the ONNX Runtime framework still contains XNNPACK symbols.

Rebuild and confirm the command includes:

```bash
--cmake_extra_defines onnxruntime_USE_XNNPACK=OFF
```

### Bad result: KleidiAI conflict remains

If log still shows:

```text
_kai_...
MediaPipeTasksCommon
onnxruntime.framework
```

then KleidiAI is still enabled.

Rebuild and confirm the command includes:

```bash
--no_kleidiai
```

Also inspect build log for:

```text
no_kleidiai=True
onnxruntime_USE_KLEIDIAI=OFF
```

### Bad result: GTMSessionFetcher conflict

If log shows:

```text
GTMSessionFetcher.framework
vs
MediaPipeTasksCommon.framework
```

then this is separate from ONNX Runtime.

Possible next steps:

1. Try another MediaPipeTasksVision version.
2. Inspect whether MediaPipeTasksCommon bundles GTMSessionFetcher internally.
3. Avoid adding another GTMSessionFetcher copy manually.
4. Verify Firebase/GoogleSignIn dependencies are not duplicated manually.

---

## Common Build Errors

### Error: Failed to resolve executable path for cmake

Install CMake:

```bash
brew install cmake
```

### Error: iOS framework build requires Xcode generator

Add:

```bash
--cmake_generator Xcode
```

### Error: missing --apple_sysroot

Add:

```bash
--apple_sysroot iphoneos
```

### Error: Compatibility with CMake < 3.5 has been removed

Add:

```bash
CMAKE_POLICY_VERSION_MINIMUM=3.5
```

inside:

```bash
--cmake_extra_defines
```

### Build succeeds but only test frameworks appear

Search specifically:

```bash
find build/iOS -path "*static_framework*onnxruntime.framework"
```

Expected:

```text
build/iOS/Release/Release-iphoneos/static_framework/onnxruntime.framework
```

---

## ABI / Platform Notes

Current command builds only:

```text
iOS device arm64
```

It does not build simulator slices.

This is enough for physical device testing and App Store builds.

If simulator support is needed later, build a simulator framework separately and combine into an xcframework.

Possible future simulator command:

```bash
./build.sh \
  --config Release \
  --build_apple_framework \
  --ios \
  --apple_sysroot iphonesimulator \
  --apple_deploy_target 13.0 \
  --osx_arch arm64 \
  --cmake_generator Xcode \
  --skip_tests \
  --use_coreml \
  --no_kleidiai \
  --cmake_extra_defines \
    onnxruntime_USE_XNNPACK=OFF \
    CMAKE_POLICY_VERSION_MINIMUM=3.5
```

Then combine device and simulator frameworks using:

```bash
xcodebuild -create-xcframework \
  -framework path/to/device/onnxruntime.framework \
  -framework path/to/simulator/onnxruntime.framework \
  -output onnxruntime.xcframework
```

Only do this if simulator testing is required.

---

## Runtime Validation Checklist

After successful build:

1. App launches on physical iPhone.
2. Microphone permission is requested.
3. Speech recognition permission is requested.
4. iOS audio plugin streams 16 kHz mono PCM int16.
5. Wakeword native init succeeds with:
   - melspectrogram.onnx
   - embedding_model.onnx
   - motion_future.onnx
6. Wakeword score changes when speaking.
7. Saying `Motion Future` triggers detection.
8. Wakeword listener stops.
9. `speech_to_text` starts.
10. Commands work:
    - start monitoring
    - stop monitoring
11. Wakeword resumes after STT ends.

---

## Do Not Commit Large Temporary Build Output

Do not commit:

```text
/Users/huynguyen/Documents/onnxruntime/build
ios/build
build
DerivedData
```

Only commit the final required framework if the project intentionally stores vendored native binaries:

```text
packages/voice_command_kit/ios/Frameworks/onnxruntime.framework
```

Confirm repository policy before committing large binaries.

---

## Summary

Use custom ONNX Runtime iOS framework with:

```text
CoreML enabled
XNNPACK disabled
KleidiAI disabled
```

This is intended to avoid duplicate symbols with:

```text
MediaPipeTasksVision / MediaPipeTasksCommon
```

The framework currently expected by Poscura local pod:

```text
packages/voice_command_kit/ios/Frameworks/onnxruntime.framework
```
