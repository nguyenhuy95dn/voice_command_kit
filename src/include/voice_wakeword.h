#pragma once

#if defined(_WIN32)
#if defined(VOICE_WAKEWORD_BUILD_DLL)
#define VOICE_WAKEWORD_EXPORT __declspec(dllexport)
#else
#define VOICE_WAKEWORD_EXPORT __declspec(dllimport)
#endif
#elif defined(__GNUC__) || defined(__clang__)
#define VOICE_WAKEWORD_EXPORT __attribute__((visibility("default")))
#else
#define VOICE_WAKEWORD_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

VOICE_WAKEWORD_EXPORT int wake_word_init(
    const char* mel_model_path,
    const char* embedding_model_path,
    const char** classifier_model_paths,
    int num_classifiers
);

VOICE_WAKEWORD_EXPORT int wake_word_process_pcm(
    const short* pcm,
    int sample_count,
    float* out_scores,
    int max_scores
);

VOICE_WAKEWORD_EXPORT void wake_word_reset();

VOICE_WAKEWORD_EXPORT void wake_word_close();

VOICE_WAKEWORD_EXPORT const char* wake_word_last_error();

VOICE_WAKEWORD_EXPORT void voice_wakeword_force_link();

#ifdef __cplusplus
}
#endif
