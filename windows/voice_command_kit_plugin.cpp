#include "voice_command_kit_plugin.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

#include <audioclient.h>
#include <combaseapi.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <mmreg.h>

namespace voice_command_kit {

using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

namespace {

constexpr char kEventChannelName[] = "voice_command_kit/pcm";
constexpr int kTargetSampleRate = 16000;

// Reads channel `channel_index` of a single interleaved frame and returns it
// scaled into roughly the int16 (-32768..32767) range as a double.
double ReadChannelSample(const uint8_t* frame, int channel_index,
                          const WAVEFORMATEX* format, bool is_float) {
  const int bytes_per_sample = format->wBitsPerSample / 8;
  const uint8_t* p = frame + static_cast<size_t>(channel_index) * bytes_per_sample;

  if (is_float && bytes_per_sample == 4) {
    float v;
    std::memcpy(&v, p, sizeof(v));
    return static_cast<double>(v) * 32768.0;
  }
  if (bytes_per_sample == 2) {
    int16_t v;
    std::memcpy(&v, p, sizeof(v));
    return static_cast<double>(v);
  }
  if (bytes_per_sample == 4) {
    int32_t v;
    std::memcpy(&v, p, sizeof(v));
    return static_cast<double>(v) / 65536.0;
  }
  if (bytes_per_sample == 3) {
    const int32_t v = (static_cast<int32_t>(static_cast<int8_t>(p[2])) << 16) |
                       (static_cast<int32_t>(p[1]) << 8) | p[0];
    return static_cast<double>(v) / 256.0;
  }
  return 0.0;
}

bool IsFloatFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    return true;
  }
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    return ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
  }
  return false;
}

}  // namespace

void VoiceCommandKitPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(
      std::make_unique<VoiceCommandKitPlugin>(registrar->messenger()));
}

VoiceCommandKitPlugin::VoiceCommandKitPlugin(flutter::BinaryMessenger* messenger)
    : messenger_(messenger) {
  WakeWordAudioHostApi::SetUp(messenger, this);

  event_channel_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, kEventChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  auto handler = std::make_unique<
      flutter::StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue*,
             std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        std::lock_guard<std::mutex> lock(sink_mutex_);
        event_sink_ = std::move(events);
        return nullptr;
      },
      [this](const EncodableValue*)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        std::lock_guard<std::mutex> lock(sink_mutex_);
        event_sink_ = nullptr;
        return nullptr;
      });
  event_channel_->SetStreamHandler(std::move(handler));
}

VoiceCommandKitPlugin::~VoiceCommandKitPlugin() {
  StopListeningInternal();
  WakeWordAudioHostApi::SetUp(messenger_, nullptr);
  event_channel_->SetStreamHandler(nullptr);
}

void VoiceCommandKitPlugin::CheckOrRequestPermission(
    std::function<void(ErrorOr<bool> reply)> result) {
  result(ErrorOr<bool>(ProbeMicrophoneAccess()));
}

void VoiceCommandKitPlugin::IsListening(
    std::function<void(ErrorOr<bool> reply)> result) {
  result(ErrorOr<bool>(running_.load()));
}

void VoiceCommandKitPlugin::StopListening(
    std::function<void(std::optional<FlutterError> reply)> result) {
  StopListeningInternal();
  result(std::nullopt);
}

bool VoiceCommandKitPlugin::ProbeMicrophoneAccess() {
  const HRESULT co_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool owns_com = co_hr == S_OK || co_hr == S_FALSE;

  bool ok = false;
  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioClient> audio_client;
  WAVEFORMATEX* mix_format = nullptr;

  do {
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                 CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
      break;
    }
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole,
                                                    &device))) {
      break;
    }
    if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                 &audio_client))) {
      break;
    }
    if (FAILED(audio_client->GetMixFormat(&mix_format))) {
      break;
    }
    if (FAILED(audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                         2000000, 0, mix_format, nullptr))) {
      break;
    }
    ok = true;
  } while (false);

  if (mix_format != nullptr) {
    CoTaskMemFree(mix_format);
  }
  if (owns_com) {
    CoUninitialize();
  }
  return ok;
}

void VoiceCommandKitPlugin::StartListening(
    std::function<void(std::optional<FlutterError> reply)> result) {
  if (running_.load()) {
    result(std::nullopt);
    return;
  }

  // Join any orphaned thread from a previous timed-out attempt before
  // reassigning capture_thread_ (assigning over a joinable std::thread
  // terminates the process).
  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }

  auto init_signal =
      std::make_shared<std::promise<std::pair<bool, std::string>>>();
  auto init_future = init_signal->get_future();

  running_.store(true);
  capture_thread_ = std::thread([this, init_signal]() {
    CaptureThreadMain(init_signal);
  });

  if (init_future.wait_for(std::chrono::seconds(5)) ==
      std::future_status::timeout) {
    running_.store(false);
    if (capture_thread_.joinable()) {
      capture_thread_.join();
    }
    result(FlutterError("AUDIO_CAPTURE_TIMEOUT",
                         "Timed out starting microphone capture"));
    return;
  }

  const auto [ok, message] = init_future.get();
  if (!ok) {
    running_.store(false);
    if (capture_thread_.joinable()) {
      capture_thread_.join();
    }
    result(FlutterError("AUDIO_CAPTURE_INIT", message));
    return;
  }

  result(std::nullopt);
}

void VoiceCommandKitPlugin::StopListeningInternal() {
  running_.store(false);
  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }
}

void VoiceCommandKitPlugin::CaptureThreadMain(
    std::shared_ptr<std::promise<std::pair<bool, std::string>>> init_signal) {
  const HRESULT co_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool owns_com = co_hr == S_OK || co_hr == S_FALSE;

  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioClient> audio_client;
  ComPtr<IAudioCaptureClient> capture_client;
  WAVEFORMATEX* mix_format = nullptr;
  bool signaled = false;

  auto fail = [&](const char* context, HRESULT hr) {
    if (!signaled) {
      char buffer[256];
      std::snprintf(buffer, sizeof(buffer), "%s (hr=0x%08lX)", context,
                    static_cast<unsigned long>(hr));
      init_signal->set_value({false, std::string(buffer)});
      signaled = true;
    }
  };

  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                 CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (FAILED(hr)) {
    fail("Failed to create MMDeviceEnumerator", hr);
  } else {
    hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
    if (FAILED(hr)) {
      fail("No default microphone device", hr);
    } else {
      hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                             &audio_client);
      if (FAILED(hr)) {
        fail("Failed to activate audio client", hr);
      } else {
        hr = audio_client->GetMixFormat(&mix_format);
        if (FAILED(hr)) {
          fail("Failed to read device mix format", hr);
        } else {
          // ~100ms shared-mode buffer.
          hr = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 1000000,
                                         0, mix_format, nullptr);
          if (FAILED(hr)) {
            fail("Failed to initialize audio client", hr);
          } else {
            hr = audio_client->GetService(IID_PPV_ARGS(&capture_client));
            if (FAILED(hr)) {
              fail("Failed to get capture client", hr);
            } else {
              hr = audio_client->Start();
              if (FAILED(hr)) {
                fail("Failed to start audio client", hr);
              }
            }
          }
        }
      }
    }
  }

  const bool init_failed = signaled;
  if (!signaled) {
    init_signal->set_value({true, ""});
  }

  if (!init_failed && audio_client && capture_client) {
    const bool is_float = IsFloatFormat(mix_format);
    const int channels = mix_format->nChannels;
    const double resample_ratio =
        static_cast<double>(mix_format->nSamplesPerSec) / kTargetSampleRate;

    std::vector<float> pending_input;
    double resample_phase = 0.0;
    std::vector<int16_t> output_buffer;

    while (running_.load()) {
      UINT32 packet_length = 0;
      if (FAILED(capture_client->GetNextPacketSize(&packet_length))) {
        break;
      }

      bool produced_any = false;
      while (packet_length != 0) {
        BYTE* data = nullptr;
        UINT32 num_frames = 0;
        DWORD flags = 0;
        if (FAILED(capture_client->GetBuffer(&data, &num_frames, &flags,
                                              nullptr, nullptr))) {
          break;
        }

        const size_t base = pending_input.size();
        pending_input.resize(base + num_frames);
        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        const int bytes_per_frame = mix_format->wBitsPerSample / 8 * channels;

        for (UINT32 i = 0; i < num_frames; ++i) {
          if (silent || data == nullptr) {
            pending_input[base + i] = 0.0f;
            continue;
          }
          const uint8_t* frame =
              reinterpret_cast<const uint8_t*>(data) +
              static_cast<size_t>(i) * bytes_per_frame;
          double sum = 0.0;
          for (int c = 0; c < channels; ++c) {
            sum += ReadChannelSample(frame, c, mix_format, is_float);
          }
          pending_input[base + i] =
              static_cast<float>(sum / std::max(1, channels));
        }

        capture_client->ReleaseBuffer(num_frames);
        produced_any = true;

        if (FAILED(capture_client->GetNextPacketSize(&packet_length))) {
          packet_length = 0;
        }
      }

      if (produced_any) {
        output_buffer.clear();
        while (true) {
          const size_t i0 = static_cast<size_t>(resample_phase);
          if (i0 + 1 >= pending_input.size()) break;
          const double t = resample_phase - static_cast<double>(i0);
          const double s = pending_input[i0] * (1.0 - t) +
                            pending_input[i0 + 1] * t;
          long v = std::lround(s);
          v = std::clamp(v, -32768L, 32767L);
          output_buffer.push_back(static_cast<int16_t>(v));
          resample_phase += resample_ratio;
        }

        const size_t consume = static_cast<size_t>(resample_phase);
        if (consume > 0) {
          const size_t clamped =
              std::min(consume, pending_input.size() > 0
                                     ? pending_input.size() - 1
                                     : 0);
          pending_input.erase(pending_input.begin(),
                               pending_input.begin() + clamped);
          resample_phase -= static_cast<double>(clamped);
        }

        if (!output_buffer.empty() && running_.load()) {
          EmitPcm(output_buffer.data(), output_buffer.size());
        }
      } else {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
    }

    audio_client->Stop();
  }

  if (mix_format != nullptr) {
    CoTaskMemFree(mix_format);
  }
  if (owns_com) {
    CoUninitialize();
  }
}

void VoiceCommandKitPlugin::EmitPcm(const int16_t* samples, size_t count) {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  if (!event_sink_) return;

  std::vector<uint8_t> bytes(count * sizeof(int16_t));
  std::memcpy(bytes.data(), samples, bytes.size());
  event_sink_->Success(EncodableValue(bytes));
}

}  // namespace voice_command_kit
