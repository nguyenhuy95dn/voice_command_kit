#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint voice_command_kit.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'voice_command_kit'
  s.version          = '1.0.0'
  s.summary          = 'Wake-word detection and voice-command recognition for Flutter on macOS.'
  s.description      = <<-DESC
Microphone capture plus ONNX Runtime-backed wake-word inference, exposed to
Flutter over method/event channels and dart:ffi.
                       DESC
  s.homepage         = 'https://github.com/Nexle-repo/poscura-app'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'NightSoft' => 'dev@poscura.local' }

  s.source           = { :path => '.' }
  # Classes/voice_wakeword_macos.cpp pulls in ../../src/voice_wakeword.cpp, the
  # core shared with the other platforms; CocoaPods only needs the files that
  # live under this directory.
  s.source_files = 'Classes/**/*.{h,m,mm,swift,cpp}'

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '13.0'

  # The wake-word symbols have to end up inside the host binary: Dart resolves
  # them with DynamicLibrary.process().
  s.static_framework = true
  s.vendored_frameworks = 'Frameworks/onnxruntime.framework'
  s.frameworks = 'Foundation', 'AVFoundation', 'CoreAudio', 'Accelerate', 'CoreML'

  # This is a *static* framework, so its C++ object files are linked directly
  # into the host binary — and the host, having no C++ sources of its own, would
  # otherwise not link a C++ standard library at all, failing on ~200 undefined
  # std:: symbols from ONNX Runtime and the wake-word core. `s.libraries` does
  # not reach the host target here, so ask for it explicitly.
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '-lc++' }

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/Frameworks/onnxruntime.framework/Headers"',
  }
  s.swift_version = '5.0'
end
