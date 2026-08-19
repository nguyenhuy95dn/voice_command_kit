#include "include/voice_wakeword.h"

#include "onnxruntime_c_api.h"

#if defined(__APPLE__)
#include "coreml_provider_factory.h"
#endif

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <limits>
#include <mutex>
#include <string>
#include <vector>

#if defined(__ANDROID__)
#include <android/log.h>
#define LOG_TAG "VoiceWakeword"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#else
#define LOGI(...) ((void)0)
#define LOGE(...) std::fprintf(stderr, __VA_ARGS__), std::fprintf(stderr, "\n")
#endif

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

namespace {

constexpr int kSampleRate = 16000;
constexpr int kChunkSamples = 1280;
constexpr int kMelspecWindowSize = 76;
constexpr int kMelspecFeatureCount = 32;
constexpr int kMelspecStepSize = 8;
constexpr int kEmbeddingSize = 96;
constexpr int kClassifierFeatureFrames = 16;
constexpr int kRawAudioMaxSamples = kSampleRate * 10;
constexpr int kMelspecMaxFrames = 10 * 97;
constexpr int kFeatureBufferMaxFrames = 120;
constexpr int kPredictionBufferMaxFrames = 30;
constexpr int kWarmupFrames = 5;

const OrtApi* g_ort = nullptr;
OrtEnv* g_env = nullptr;
OrtSessionOptions* g_session_options = nullptr;
OrtSession* g_mel_session = nullptr;
OrtSession* g_embedding_session = nullptr;
std::vector<OrtSession*> g_classifier_sessions;
OrtMemoryInfo* g_memory_info = nullptr;
OrtAllocator* g_allocator = nullptr;

std::mutex g_mutex;
std::string g_last_error;

std::string g_mel_input_name = "input";
std::string g_mel_output_name = "output";
std::string g_embedding_input_name = "input_1";
std::string g_embedding_output_name = "conv2d_19";
std::vector<std::string> g_classifier_input_names;
std::vector<std::string> g_classifier_output_names;

std::deque<int16_t> g_raw_audio_buffer;
std::vector<int16_t> g_raw_data_remainder;
int g_accumulated_samples = 0;
std::deque<std::array<float, kMelspecFeatureCount>> g_melspectrogram_buffer;
std::deque<std::array<float, kEmbeddingSize>> g_feature_buffer;
std::vector<std::deque<float>> g_prediction_buffers;
std::vector<bool> g_classifier_active;

void set_error(const std::string& message) {
    g_last_error = message;
    LOGE("%s", message.c_str());
}

bool check_status(OrtStatus* status, const char* context) {
    if (status == nullptr) {
        return true;
    }

    const char* message = g_ort->GetErrorMessage(status);
    set_error(std::string(context) + ": " + (message ? message : "unknown ONNX Runtime error"));
    g_ort->ReleaseStatus(status);
    return false;
}

void trim_raw_audio_buffer() {
    while (static_cast<int>(g_raw_audio_buffer.size()) > kRawAudioMaxSamples) {
        g_raw_audio_buffer.pop_front();
    }
}

void reset_buffers() {
    g_raw_audio_buffer.clear();
    g_raw_data_remainder.clear();
    g_accumulated_samples = 0;
    g_melspectrogram_buffer.clear();
    g_feature_buffer.clear();
    for (auto& buffer : g_prediction_buffers) {
        buffer.clear();
    }

    for (int i = 0; i < kMelspecWindowSize; ++i) {
        std::array<float, kMelspecFeatureCount> row{};
        row.fill(1.0f);
        g_melspectrogram_buffer.push_back(row);
    }

    for (int i = 0; i < kFeatureBufferMaxFrames; ++i) {
        std::array<float, kEmbeddingSize> row{};
        row.fill(0.0f);
        g_feature_buffer.push_back(row);
    }
}

void release_all() {
    for (OrtSession* session : g_classifier_sessions) {
        if (session != nullptr) {
            g_ort->ReleaseSession(session);
        }
    }
    g_classifier_sessions.clear();
    g_classifier_input_names.clear();
    g_classifier_output_names.clear();
    g_prediction_buffers.clear();
    g_classifier_active.clear();
    if (g_embedding_session != nullptr) {
        g_ort->ReleaseSession(g_embedding_session);
        g_embedding_session = nullptr;
    }
    if (g_mel_session != nullptr) {
        g_ort->ReleaseSession(g_mel_session);
        g_mel_session = nullptr;
    }
    if (g_memory_info != nullptr) {
        g_ort->ReleaseMemoryInfo(g_memory_info);
        g_memory_info = nullptr;
    }
    if (g_session_options != nullptr) {
        g_ort->ReleaseSessionOptions(g_session_options);
        g_session_options = nullptr;
    }
    if (g_env != nullptr) {
        g_ort->ReleaseEnv(g_env);
        g_env = nullptr;
    }

    g_allocator = nullptr;
    reset_buffers();
}

#if defined(_WIN32)
std::wstring utf8_to_wide(const char* utf8) {
    if (utf8 == nullptr || utf8[0] == '\0') return std::wstring();
    const int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (len <= 0) return std::wstring();
    std::wstring wide(static_cast<size_t>(len - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide.data(), len);
    return wide;
}
#endif

bool create_session(const char* path, OrtSession** out_session) {
    const std::string context = std::string("CreateSession failed: ") + path;
#if defined(_WIN32)
    const std::wstring wide_path = utf8_to_wide(path);
    return check_status(
        g_ort->CreateSession(g_env, wide_path.c_str(), g_session_options, out_session),
        context.c_str()
    );
#else
    return check_status(
        g_ort->CreateSession(g_env, path, g_session_options, out_session),
        context.c_str()
    );
#endif
}

bool read_session_io_name(
    OrtSession* session,
    bool is_input,
    std::string* out_name
) {
    char* raw_name = nullptr;
    OrtStatus* status = is_input
        ? g_ort->SessionGetInputName(session, 0, g_allocator, &raw_name)
        : g_ort->SessionGetOutputName(session, 0, g_allocator, &raw_name);
    if (!check_status(status, is_input ? "SessionGetInputName failed" : "SessionGetOutputName failed")) {
        return false;
    }

    out_name->assign(raw_name != nullptr ? raw_name : "");
    g_allocator->Free(g_allocator, raw_name);
    return true;
}

bool append_prediction(size_t classifier_idx, float score) {
    if (classifier_idx >= g_prediction_buffers.size()) return false;
    
    g_prediction_buffers[classifier_idx].push_back(score);
    while (static_cast<int>(g_prediction_buffers[classifier_idx].size()) > kPredictionBufferMaxFrames) {
        g_prediction_buffers[classifier_idx].pop_front();
    }
    return static_cast<int>(g_prediction_buffers[classifier_idx].size()) >= kWarmupFrames;
}

bool run_session(
    OrtSession* session,
    const std::string& input_name,
    const std::string& output_name,
    const std::vector<float>& input_data,
    const std::vector<int64_t>& input_shape,
    OrtValue** output_value
) {
    *output_value = nullptr;

    OrtValue* input_tensor = nullptr;
    if (!check_status(
            g_ort->CreateTensorWithDataAsOrtValue(
                g_memory_info,
                const_cast<float*>(input_data.data()),
                input_data.size() * sizeof(float),
                input_shape.data(),
                static_cast<size_t>(input_shape.size()),
                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                &input_tensor
            ),
            "CreateTensorWithDataAsOrtValue failed")) {
        return false;
    }

    const char* input_names[] = {input_name.c_str()};
    const char* output_names[] = {output_name.c_str()};
    bool ok = check_status(
        g_ort->Run(
            session,
            nullptr,
            input_names,
            reinterpret_cast<const OrtValue* const*>(&input_tensor),
            1,
            output_names,
            1,
            output_value
        ),
        "Ort Run failed"
    );

    g_ort->ReleaseValue(input_tensor);
    return ok;
}

bool copy_tensor_data(OrtValue* value, std::vector<float>* out_data, std::vector<int64_t>* out_shape) {
    OrtTensorTypeAndShapeInfo* shape_info = nullptr;
    if (!check_status(g_ort->GetTensorTypeAndShape(value, &shape_info), "GetTensorTypeAndShape failed")) {
        return false;
    }

    size_t dim_count = 0;
    if (!check_status(g_ort->GetDimensionsCount(shape_info, &dim_count), "GetDimensionsCount failed")) {
        g_ort->ReleaseTensorTypeAndShapeInfo(shape_info);
        return false;
    }

    out_shape->assign(dim_count, 0);
    if (!out_shape->empty() &&
        !check_status(g_ort->GetDimensions(shape_info, out_shape->data(), dim_count), "GetDimensions failed")) {
        g_ort->ReleaseTensorTypeAndShapeInfo(shape_info);
        return false;
    }

    size_t element_count = 0;
    if (!check_status(g_ort->GetTensorShapeElementCount(shape_info, &element_count), "GetTensorShapeElementCount failed")) {
        g_ort->ReleaseTensorTypeAndShapeInfo(shape_info);
        return false;
    }
    g_ort->ReleaseTensorTypeAndShapeInfo(shape_info);

    float* raw = nullptr;
    if (!check_status(g_ort->GetTensorMutableData(value, reinterpret_cast<void**>(&raw)), "GetTensorMutableData failed")) {
        return false;
    }

    out_data->assign(raw, raw + element_count);
    return true;
}

bool run_melspectrogram(
    const std::vector<int16_t>& pcm,
    std::vector<std::array<float, kMelspecFeatureCount>>* out_frames
) {
    std::vector<float> input_data;
    input_data.reserve(pcm.size());
    for (int16_t sample : pcm) {
        input_data.push_back(static_cast<float>(sample));
    }

    OrtValue* output_value = nullptr;
    if (!run_session(
            g_mel_session,
            g_mel_input_name,
            g_mel_output_name,
            input_data,
            {1, static_cast<int64_t>(input_data.size())},
            &output_value)) {
        return false;
    }

    std::vector<float> output_data;
    std::vector<int64_t> output_shape;
    const bool ok = copy_tensor_data(output_value, &output_data, &output_shape);
    g_ort->ReleaseValue(output_value);
    if (!ok) {
        return false;
    }

    int64_t rows = 0;
    int64_t cols = 0;
    if (output_shape.size() >= 2) {
        cols = output_shape.back();
        rows = output_shape[output_shape.size() - 2];
    }
    if (cols != kMelspecFeatureCount || rows <= 0) {
        set_error("Unexpected mel spectrogram output shape");
        return false;
    }

    out_frames->clear();
    out_frames->reserve(static_cast<size_t>(rows));
    for (int64_t row = 0; row < rows; ++row) {
        std::array<float, kMelspecFeatureCount> frame{};
        for (int col = 0; col < kMelspecFeatureCount; ++col) {
            const size_t ndx = static_cast<size_t>(row * kMelspecFeatureCount + col);
            frame[col] = output_data[ndx] / 10.0f + 2.0f;
        }
        out_frames->push_back(frame);
    }

    return true;
}

bool run_embedding_window(
    const std::array<float, kMelspecWindowSize * kMelspecFeatureCount>& window,
    std::array<float, kEmbeddingSize>* out_embedding
) {
    std::vector<float> input_data(window.begin(), window.end());

    OrtValue* output_value = nullptr;
    if (!run_session(
            g_embedding_session,
            g_embedding_input_name,
            g_embedding_output_name,
            input_data,
            {1, kMelspecWindowSize, kMelspecFeatureCount, 1},
            &output_value)) {
        return false;
    }

    std::vector<float> output_data;
    std::vector<int64_t> output_shape;
    const bool ok = copy_tensor_data(output_value, &output_data, &output_shape);
    g_ort->ReleaseValue(output_value);
    if (!ok) {
        return false;
    }

    if (output_data.size() < kEmbeddingSize) {
        set_error("Unexpected embedding output size");
        return false;
    }

    std::copy_n(output_data.begin(), kEmbeddingSize, out_embedding->begin());
    return true;
}

bool run_classifier_window(
    size_t classifier_idx,
    const std::array<float, kClassifierFeatureFrames * kEmbeddingSize>& features,
    float* out_score
) {
    if (classifier_idx >= g_classifier_sessions.size()) return false;
    
    std::vector<float> input_data(features.begin(), features.end());

    OrtValue* output_value = nullptr;
    if (!run_session(
            g_classifier_sessions[classifier_idx],
            g_classifier_input_names[classifier_idx],
            g_classifier_output_names[classifier_idx],
            input_data,
            {1, kClassifierFeatureFrames, kEmbeddingSize},
            &output_value)) {
        return false;
    }

    std::vector<float> output_data;
    std::vector<int64_t> output_shape;
    const bool ok = copy_tensor_data(output_value, &output_data, &output_shape);
    g_ort->ReleaseValue(output_value);
    if (!ok) {
        return false;
    }

    if (output_data.empty()) {
        set_error("Classifier returned empty output");
        return false;
    }

    *out_score = output_data.front();
    return true;
}

void buffer_raw_audio(const std::vector<int16_t>& samples) {
    for (int16_t sample : samples) {
        g_raw_audio_buffer.push_back(sample);
    }
    trim_raw_audio_buffer();
}

bool streaming_melspectrogram(int n_samples) {
    if (static_cast<int>(g_raw_audio_buffer.size()) < 400) {
        set_error("The number of input frames must be at least 400 samples @ 16khz (25 ms)");
        return false;
    }

    const int window_samples = std::min(
        static_cast<int>(g_raw_audio_buffer.size()),
        n_samples + 160 * 3
    );

    std::vector<int16_t> slice;
    slice.reserve(static_cast<size_t>(window_samples));
    const int start = static_cast<int>(g_raw_audio_buffer.size()) - window_samples;
    for (int i = start; i < static_cast<int>(g_raw_audio_buffer.size()); ++i) {
        slice.push_back(g_raw_audio_buffer[static_cast<size_t>(i)]);
    }

    std::vector<std::array<float, kMelspecFeatureCount>> frames;
    if (!run_melspectrogram(slice, &frames)) {
        return false;
    }

    for (const auto& frame : frames) {
        g_melspectrogram_buffer.push_back(frame);
    }
    while (static_cast<int>(g_melspectrogram_buffer.size()) > kMelspecMaxFrames) {
        g_melspectrogram_buffer.pop_front();
    }

    return true;
}

std::array<float, kMelspecWindowSize * kMelspecFeatureCount> make_melspec_window(int start_index) {
    std::array<float, kMelspecWindowSize * kMelspecFeatureCount> window{};
    size_t dst = 0;
    for (int row = 0; row < kMelspecWindowSize; ++row) {
        const auto& source = g_melspectrogram_buffer[static_cast<size_t>(start_index + row)];
        std::copy(source.begin(), source.end(), window.begin() + static_cast<long>(dst));
        dst += kMelspecFeatureCount;
    }
    return window;
}

std::array<float, kClassifierFeatureFrames * kEmbeddingSize> make_feature_window(int start_index) {
    std::array<float, kClassifierFeatureFrames * kEmbeddingSize> window{};
    size_t dst = 0;
    for (int row = 0; row < kClassifierFeatureFrames; ++row) {
        const auto& source = g_feature_buffer[static_cast<size_t>(start_index + row)];
        std::copy(source.begin(), source.end(), window.begin() + static_cast<long>(dst));
        dst += kEmbeddingSize;
    }
    return window;
}

int streaming_features(const std::vector<int16_t>& input_samples) {
    std::vector<int16_t> samples = input_samples;
    int processed_samples = 0;

    if (!g_raw_data_remainder.empty()) {
        std::vector<int16_t> combined;
        combined.reserve(g_raw_data_remainder.size() + samples.size());
        combined.insert(combined.end(), g_raw_data_remainder.begin(), g_raw_data_remainder.end());
        combined.insert(combined.end(), samples.begin(), samples.end());
        samples.swap(combined);
        g_raw_data_remainder.clear();
    }

    if (g_accumulated_samples + static_cast<int>(samples.size()) >= kChunkSamples) {
        const int remainder = (g_accumulated_samples + static_cast<int>(samples.size())) % kChunkSamples;
        if (remainder != 0) {
            const size_t even_length = samples.size() - static_cast<size_t>(remainder);
            std::vector<int16_t> even_samples(samples.begin(), samples.begin() + static_cast<long>(even_length));
            buffer_raw_audio(even_samples);
            g_accumulated_samples += static_cast<int>(even_samples.size());
            g_raw_data_remainder.assign(samples.end() - remainder, samples.end());
        } else {
            buffer_raw_audio(samples);
            g_accumulated_samples += static_cast<int>(samples.size());
            g_raw_data_remainder.clear();
        }
    } else {
        buffer_raw_audio(samples);
        g_accumulated_samples += static_cast<int>(samples.size());
    }

    if (g_accumulated_samples >= kChunkSamples && g_accumulated_samples % kChunkSamples == 0) {
        if (!streaming_melspectrogram(g_accumulated_samples)) {
            return -1;
        }

        for (int i = g_accumulated_samples / kChunkSamples - 1; i >= 0; --i) {
            int ndx = -kMelspecStepSize * i;
            int end_index = ndx != 0
                ? static_cast<int>(g_melspectrogram_buffer.size()) + ndx
                : static_cast<int>(g_melspectrogram_buffer.size());
            int start_index = end_index - kMelspecWindowSize;
            if (start_index < 0 || end_index > static_cast<int>(g_melspectrogram_buffer.size())) {
                continue;
            }

            std::array<float, kMelspecWindowSize * kMelspecFeatureCount> window =
                make_melspec_window(start_index);
            std::array<float, kEmbeddingSize> embedding{};
            if (!run_embedding_window(window, &embedding)) {
                return -1;
            }

            g_feature_buffer.push_back(embedding);
            while (static_cast<int>(g_feature_buffer.size()) > kFeatureBufferMaxFrames) {
                g_feature_buffer.pop_front();
            }
        }

        processed_samples = g_accumulated_samples;
        g_accumulated_samples = 0;
    }

    return processed_samples != 0 ? processed_samples : g_accumulated_samples;
}

bool classifier_predict_for_offset(size_t classifier_idx, int offset, float* out_score) {
    const int start_index = static_cast<int>(g_feature_buffer.size()) - kClassifierFeatureFrames - offset;
    if (start_index < 0) {
        *out_score = 0.0f;
        return true;
    }

    std::array<float, kClassifierFeatureFrames * kEmbeddingSize> window =
        make_feature_window(start_index);
    return run_classifier_window(classifier_idx, window, out_score);
}

bool run_pipeline_once_if_ready(const std::vector<int16_t>& pcm, std::vector<float>* out_scores) {
    const int prepared_samples = streaming_features(pcm);
    if (prepared_samples < 0) {
        return false;
    }
    
    out_scores->assign(g_classifier_sessions.size(), 0.0f);

    if (prepared_samples > kChunkSamples) {
        for (size_t c = 0; c < g_classifier_sessions.size(); ++c) {
            if (c < g_classifier_active.size() && !g_classifier_active[c]) continue;
            float max_score = -std::numeric_limits<float>::infinity();
            for (int i = prepared_samples / kChunkSamples - 1; i >= 0; --i) {
                float candidate = 0.0f;
                if (!classifier_predict_for_offset(c, i, &candidate)) {
                    return false;
                }
                max_score = std::max(max_score, candidate);
            }
            float final_score = std::isfinite(max_score) ? max_score : 0.0f;
            if (append_prediction(c, final_score)) {
                (*out_scores)[c] = final_score;
            }
        }
    } else if (prepared_samples == kChunkSamples) {
        for (size_t c = 0; c < g_classifier_sessions.size(); ++c) {
            if (c < g_classifier_active.size() && !g_classifier_active[c]) continue;
            float score = 0.0f;
            if (!classifier_predict_for_offset(c, 0, &score)) {
                return false;
            }
            if (append_prediction(c, score)) {
                (*out_scores)[c] = score;
            }
        }
    } else {
        for (size_t c = 0; c < g_classifier_sessions.size(); ++c) {
            if (c < g_classifier_active.size() && !g_classifier_active[c]) continue;
            if (!g_prediction_buffers[c].empty()) {
                float score = g_prediction_buffers[c].back();
                if (append_prediction(c, score)) {
                    (*out_scores)[c] = score;
                }
            }
        }
    }

    return true;
}

}  // namespace

extern "C" {

int wake_word_init(
    const char* mel_model_path,
    const char* embedding_model_path,
    const char** classifier_model_paths,
    int num_classifiers
) {
    std::lock_guard<std::mutex> lock(g_mutex);
    release_all();
    g_last_error.clear();

    g_ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (g_ort == nullptr) {
        set_error("Failed to get ONNX Runtime API");
        return 0;
    }

    if (!check_status(g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "voice_wakeword", &g_env), "CreateEnv failed")) {
        release_all();
        return 0;
    }

    if (!check_status(g_ort->CreateSessionOptions(&g_session_options), "CreateSessionOptions failed")) {
        release_all();
        return 0;
    }

    g_ort->SetIntraOpNumThreads(g_session_options, 1);
    g_ort->SetInterOpNumThreads(g_session_options, 1);
    g_ort->SetSessionGraphOptimizationLevel(g_session_options, ORT_ENABLE_ALL);

#if defined(__APPLE__)
    // Offload inference to the ANE/GPU via CoreML where the graph allows it.
    // COREML_FLAG_USE_NONE lets CoreML pick the best compute unit per node;
    // any node it can't take stays on the CPU EP, which is always the
    // implicit fallback — so a failure to attach here must not abort init,
    // it just means every node runs on CPU as before.
    check_status(
        OrtSessionOptionsAppendExecutionProvider_CoreML(g_session_options, COREML_FLAG_USE_NONE),
        "CoreML EP unavailable, falling back to CPU"
    );
#endif

    if (!check_status(
            g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &g_memory_info),
            "CreateCpuMemoryInfo failed")) {
        release_all();
        return 0;
    }

    if (!check_status(g_ort->GetAllocatorWithDefaultOptions(&g_allocator), "GetAllocatorWithDefaultOptions failed")) {
        release_all();
        return 0;
    }

    if (!create_session(mel_model_path, &g_mel_session) ||
        !create_session(embedding_model_path, &g_embedding_session)) {
        release_all();
        return 0;
    }

    g_classifier_sessions.resize(num_classifiers, nullptr);
    g_classifier_input_names.resize(num_classifiers);
    g_classifier_output_names.resize(num_classifiers);
    g_prediction_buffers.resize(num_classifiers);
    // All active until the host calls wake_word_set_active — matches the old
    // behavior for callers that never opt into filtering.
    g_classifier_active.assign(num_classifiers, true);

    for (int i = 0; i < num_classifiers; ++i) {
        if (!create_session(classifier_model_paths[i], &g_classifier_sessions[i])) {
            release_all();
            return 0;
        }
    }

    if (!read_session_io_name(g_mel_session, true, &g_mel_input_name) ||
        !read_session_io_name(g_mel_session, false, &g_mel_output_name) ||
        !read_session_io_name(g_embedding_session, true, &g_embedding_input_name) ||
        !read_session_io_name(g_embedding_session, false, &g_embedding_output_name)) {
        release_all();
        return 0;
    }

    for (int i = 0; i < num_classifiers; ++i) {
        if (!read_session_io_name(g_classifier_sessions[i], true, &g_classifier_input_names[i]) ||
            !read_session_io_name(g_classifier_sessions[i], false, &g_classifier_output_names[i])) {
            release_all();
            return 0;
        }
    }

    reset_buffers();
    LOGI("wake_word_init success");
    return 1;
}

int wake_word_process_pcm(const short* pcm, int sample_count, float* out_scores, int max_scores) {
    std::lock_guard<std::mutex> lock(g_mutex);

    if (pcm == nullptr || sample_count <= 0 || out_scores == nullptr || max_scores <= 0) {
        set_error("Invalid PCM buffer or scores output");
        return -1;
    }

    if (g_mel_session == nullptr || g_embedding_session == nullptr || g_classifier_sessions.empty()) {
        set_error("wake_word_process_pcm called before wake_word_init");
        return -1;
    }

    std::vector<int16_t> pcm_buffer(
        pcm,
        pcm + static_cast<size_t>(sample_count)
    );
    
    std::vector<float> scores;
    if (!run_pipeline_once_if_ready(pcm_buffer, &scores)) {
        return -1;
    }
    
    int num_written = std::min(static_cast<int>(scores.size()), max_scores);
    for (int i = 0; i < num_written; ++i) {
        out_scores[i] = scores[i];
    }
    
    return num_written;
}

void wake_word_set_active(const int* indices, int count) {
    std::lock_guard<std::mutex> lock(g_mutex);
    std::fill(g_classifier_active.begin(), g_classifier_active.end(), false);
    for (int i = 0; i < count; ++i) {
        const int idx = indices[i];
        if (idx >= 0 && static_cast<size_t>(idx) < g_classifier_active.size()) {
            g_classifier_active[static_cast<size_t>(idx)] = true;
        }
    }
}

void wake_word_reset() {
    std::lock_guard<std::mutex> lock(g_mutex);
    reset_buffers();
    g_last_error.clear();
}

void wake_word_close() {
    std::lock_guard<std::mutex> lock(g_mutex);
    release_all();
}

const char* wake_word_last_error() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_last_error.c_str();
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((used))
#endif
static void* const g_forced_symbols[] = {
    (void*)&wake_word_init,
    (void*)&wake_word_process_pcm,
    (void*)&wake_word_set_active,
    (void*)&wake_word_reset,
    (void*)&wake_word_close,
    (void*)&wake_word_last_error,
};

volatile int g_forced_link_dummy = 0;

void voice_wakeword_force_link() {
    g_forced_link_dummy = (int)reinterpret_cast<intptr_t>(g_forced_symbols);
}

}  // extern "C"
