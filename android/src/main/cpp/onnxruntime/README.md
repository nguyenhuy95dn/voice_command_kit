Installed ONNX Runtime Android `1.26.0` files from the official
`onnxruntime-android-1.26.0.aar` package.

Required layout:

- `include/onnxruntime_c_api.h`
- `lib/arm64-v8a/libonnxruntime.so`
- `lib/x86_64/libonnxruntime.so`

Once those files exist, `android/app/build.gradle.kts` automatically enables
the native wakeword module and packages `libonnxruntime.so` into the APK.
