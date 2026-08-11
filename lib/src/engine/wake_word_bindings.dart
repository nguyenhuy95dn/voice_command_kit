import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Thin FFI wrapper over the `wake_word_*` C API in `src/voice_wakeword.cpp`.
final class WakeWordBindings {
  WakeWordBindings._();

  static final DynamicLibrary _lib = _openLibrary();
  static final _WakeWordSymbols _symbols = _WakeWordSymbols(_lib);

  static DynamicLibrary _openLibrary() {
    try {
      if (Platform.isAndroid) {
        return DynamicLibrary.open('libvoice_wakeword.so');
      }
      if (Platform.isIOS || Platform.isMacOS) {
        // On both Apple platforms the wake word runtime is compiled into the
        // host executable via this package's pod and kept alive by
        // voice_wakeword_force_link(), so the symbols live in the process.
        return DynamicLibrary.process();
      }
      if (Platform.isWindows) {
        return DynamicLibrary.open('voice_wakeword.dll');
      }
      throw UnsupportedError(
        'Unsupported wake word platform: ${Platform.operatingSystem}',
      );
    } on Object catch (error) {
      throw StateError(
        Platform.isAndroid
            ? 'Failed to load libvoice_wakeword.so. Check that the '
                  'voice_command_kit Android module built its native target. '
                  'Original error: $error'
            : (Platform.isIOS || Platform.isMacOS)
            ? 'Failed to access wake word symbols from the '
                  '${Platform.operatingSystem} process. Ensure the '
                  'voice_command_kit pod is linked into the host binary. '
                  'Original error: $error'
            : Platform.isWindows
            ? 'Failed to load voice_wakeword.dll. Ensure it and '
                  'onnxruntime.dll sit next to the built exe (the plugin '
                  'bundles both). Original error: $error'
            : 'Failed to open wake word library: $error',
      );
    }
  }

  /// Loads the shared feature models plus every classifier, in order. The index
  /// a classifier gets here is the index its score is reported at by
  /// [processPcm].
  static void init({
    required String melModelPath,
    required String embeddingModelPath,
    required List<String> classifierModelPaths,
  }) {
    final mel = melModelPath.toNativeUtf8();
    final embedding = embeddingModelPath.toNativeUtf8();
    final numClassifiers = classifierModelPaths.length;
    final classifiers = calloc<Pointer<Utf8>>(numClassifiers);

    for (int i = 0; i < numClassifiers; i++) {
      classifiers[i] = classifierModelPaths[i].toNativeUtf8();
    }

    try {
      final ok = _symbols.init(mel, embedding, classifiers, numClassifiers);
      if (ok != 1) {
        throw StateError('wake_word_init failed: ${lastError()}');
      }
    } finally {
      calloc.free(mel);
      calloc.free(embedding);
      for (int i = 0; i < numClassifiers; i++) {
        calloc.free(classifiers[i]);
      }
      calloc.free(classifiers);
    }
  }

  /// Feeds one PCM chunk and returns the score of every loaded classifier, in
  /// load order. Empty when the native side produced nothing.
  static List<double> processPcm(Int16List pcm, int maxScores) {
    if (pcm.isEmpty || maxScores <= 0) return [];

    final ptr = calloc<Int16>(pcm.length);
    final scoresPtr = calloc<Float>(maxScores);
    try {
      ptr.asTypedList(pcm.length).setAll(0, pcm);
      final numWritten = _symbols.processPcm(
        ptr,
        pcm.length,
        scoresPtr,
        maxScores,
      );
      if (numWritten <= 0) return [];

      return scoresPtr.asTypedList(numWritten).toList();
    } finally {
      calloc.free(ptr);
      calloc.free(scoresPtr);
    }
  }

  static void reset() => _symbols.reset();

  static void close() => _symbols.close();

  static String lastError() {
    final ptr = _symbols.lastError();
    if (ptr == nullptr) return '';
    return ptr.toDartString();
  }
}

final class _WakeWordSymbols {
  _WakeWordSymbols(this._lib) {
    try {
      init = _lib
          .lookupFunction<
            Int32 Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Pointer<Utf8>>,
              Int32,
            ),
            int Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Pointer<Utf8>>,
              int,
            )
          >('wake_word_init');
      processPcm = _lib
          .lookupFunction<
            Int32 Function(Pointer<Int16>, Int32, Pointer<Float>, Int32),
            int Function(Pointer<Int16>, int, Pointer<Float>, int)
          >('wake_word_process_pcm');
      reset = _lib.lookupFunction<Void Function(), void Function()>(
        'wake_word_reset',
      );
      close = _lib.lookupFunction<Void Function(), void Function()>(
        'wake_word_close',
      );
      lastError = _lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'wake_word_last_error',
          );
    } on Object catch (error) {
      throw StateError(
        (Platform.isIOS || Platform.isMacOS)
            ? 'The voice_command_kit pod is linked on '
                  '${Platform.operatingSystem} but wake_word_* exports are '
                  'still missing. Original error: $error'
            : 'Failed to bind wake word native symbols. Original error: $error',
      );
    }
  }

  final DynamicLibrary _lib;
  late final int Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Pointer<Utf8>>,
    int,
  )
  init;
  late final int Function(Pointer<Int16>, int, Pointer<Float>, int) processPcm;
  late final void Function() reset;
  late final void Function() close;
  late final Pointer<Utf8> Function() lastError;
}
