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

/// Restricts inference to the classifiers at [indices] (into the load order
/// from wake_word_init) on the next call to wake_word_process_pcm. Others are
/// skipped entirely — not just ignored — so this is what actually saves the
/// CPU cost of running every command classifier while only the wake word is
/// wanted. Passing every loaded index (or never calling this) runs them all,
/// same as before this existed.
VOICE_WAKEWORD_EXPORT void wake_word_set_active(const int* indices, int count);

VOICE_WAKEWORD_EXPORT void wake_word_reset();

VOICE_WAKEWORD_EXPORT void wake_word_close();

VOICE_WAKEWORD_EXPORT const char* wake_word_last_error();

VOICE_WAKEWORD_EXPORT void voice_wakeword_force_link();

#ifdef __cplusplus
}
#endif
