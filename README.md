# voice_command_kit

On-device wake-word detection and voice-command recognition for Flutter, on
**Android, iOS, macOS and Windows**.

You supply the models and the phrases; the package supplies everything between
the microphone and a command callback. It carries no knowledge of the host app —
no DI container, no router, no settings store, no toasts of its own.

```
mic ──► native capture ──► 16 kHz mono PCM ──► wake-word engine (ONNX)
                                                      │ wake word fires
                                                      ▼
                                        speech-to-text  ──or──  command models
                                                      │
                                                      ▼
                                            onCommand('turn_on')
```

## Requirements

- Flutter `3.41.9` (stable channel), Dart `3.11.5` — see [CLAUDE.md](CLAUDE.md)
  for the full per-platform toolchain (Android/iOS/macOS/Windows).

## Quick start (demo)

The fastest way to see it working is the bundled example app — it wakes on
**"Hey Sunny"** and recognizes **"turn on"** / **"turn off"** to flip a light
on screen. Its models are bundled, so it runs as-is:

```bash
cd example
flutter run            # add -d macos / -d windows as needed
```

See [example/README.md](example/README.md) for what's bundled and how to
swap in your own wake word / commands.

## Using it

```dart
const config = VoicePipelineConfig(
  features: FeatureModels(
    melSpectrogram: ModelSource.asset('assets/models/melspectrogram.onnx'),
    embedding: ModelSource.asset('assets/models/embedding_model.onnx'),
  ),
  wakeWord: WakeWordModel(
    id: 'hey_sunny',
    classifier: ModelSource.asset('assets/models/hey_sunny.onnx'),
  ),
  commands: [
    VoiceCommand(
      id: 'turn_on',
      phrases: ['turn on', 'turn on the lights'],
      classifier: ModelSource.asset('assets/models/turn_on.onnx'),
    ),
  ],
);

final pipeline = VoicePipeline(
  config: config,
  onCommand: (id) async => runCommand(id),           // returns whether it ran
  availableCommands: () => currentlyValidCommandIds(),
  logger: MyLogger(),
  notifier: MyNotifier(),
);

await pipeline.start();
```

That is the whole integration. See `example/` for a runnable version.

### What the host still owns

| Question | How you answer it |
|---|---|
| Should we be listening at all? | call `start()` / `stop()` |
| Which commands make sense right now? | `availableCommands` |
| What does this command do? | `onCommand` |
| Can speech-to-text have the mic? | `canUseSpeechToTextNow` |
| A model failed to load — now what? | `onEngineInitFailed` |
| Where do diagnostics and user feedback go? | `logger`, `notifier` |

`availableCommands` is taken at face value — the package never second-guesses
it. Returning an empty list means the wake word is heard but no session opens.

### Model load failures

`wake_word_init` loads every configured model — the wake word and every
command's classifier — in one native call, so a single missing or broken file
fails the whole engine, not just the command it belonged to. That failure is
also what the health-check watchdog retries every `healthCheckInterval`
(10s by default) whenever capture isn't running — the right thing to do for
"no microphone yet," but not for a model that will never load no matter how
many times you ask.

`onEngineInitFailed` reports every one of those attempts, not just the first,
so you can tell the two apart:

```dart
onEngineInitFailed: (error, stackTrace) {
  if (error is ModelLoadFailure) {
    // Permanent — nothing about retrying fixes a missing file. error.message
    // names every model that failed to resolve.
    crashReporter.recordError(error, stackTrace);
    pipeline.stop();       // give up rather than retry forever
  } else {
    logger.warn('wake word init failed, will keep retrying', error);
  }
},
```

The package never decides this for you — same as every other judgement call
above, it only reports.

## Recognition modes

A command carries `phrases` (matched against a transcript), a `classifier` (a
model trained on the phrase), or both.

- `CommandRecognitionMode.speechToText` — the wake word releases the microphone
  to speech-to-text. Best recall, needs a working platform recognizer.
- `CommandRecognitionMode.wakeWordModel` — fully offline; the wake word swaps
  the engine onto the command models and the next detection *is* the command.
- `CommandRecognitionMode.auto` (default) — speech-to-text everywhere except
  Windows, which has no platform recognizer worth relying on.

Supplying both kinds lets one configuration serve both, and lets a
speech-to-text session degrade to models when `canUseSpeechToTextNow` returns
false — typically because something else (a recording) holds the microphone.

Speech-to-text sits behind the `SpeechRecognizer` interface. The default
implementation wraps the `speech_to_text` plugin; implement your own for a local
model or a cloud service.

## Models

The package ships **no model files**. The engine follows the
[openWakeWord](https://github.com/dscripka/openWakeWord) topology and needs
three kinds of ONNX model, all provided by the consumer:

| Model | Role | Reusable |
|---|---|---|
| melspectrogram | audio → mel frames | generic |
| embedding | mel frames → embeddings | generic |
| classifier | embeddings → score, one per phrase | trained per phrase |

Any of them can come from a Flutter asset, a file on disk, or raw bytes
(`ModelSource.asset` / `.file` / `.bytes`). Assets and bytes are materialised
into the application support directory and reused across launches.

Every classifier is loaded natively at init, not per session: loading is far too
slow to do when the wake word fires. Switching which ones may fire is then just
`setActive`.

`doc/TRAINING_MODELS.md` walks through training a classifier for a new phrase.

## Platform notes

| Platform | Engine | Capture |
|---|---|---|
| Android | `libvoice_wakeword.so`, built by the plugin's CMake | `AudioRecord` |
| iOS | compiled into the host binary via the pod | `AVAudioEngine` + `AVAudioSession` |
| macOS | compiled into the host binary via the pod | `AVAudioEngine`, CoreAudio device listener |
| Windows | `voice_wakeword.dll`, bundled with `onnxruntime.dll` | WASAPI |

On Apple platforms Dart reaches the engine through
`DynamicLibrary.process()`, which is why the pods are static frameworks and each
plugin's `register()` calls `voice_wakeword_force_link()` — without a reference
the linker would strip the exports. The iOS **simulator** has no ONNX Runtime
slice and gets a stub that links but reports inference as unavailable.

macOS is the only platform that implements the device-change event channel.
Others produce `MissingPluginException`, which the Dart side ignores by design,
so a platform gains the behaviour simply by starting to emit.

`NATIVE.md` documents the C++ core and the macOS capture pitfalls in detail —
read it before touching either. `doc/ONNX_RUNTIME_IOS_CUSTOM_BUILD.md` covers
rebuilding the vendored iOS runtime, which is a custom build because the stock
one conflicts with MediaPipe Tasks.

### iOS/macOS: required build setting for real (archived) builds

Add **`STRIP_STYLE = non-global`** to the host app's Release configuration —
Xcode Build Settings → Deploy → Strip Style → **Non-Global Symbols** — on both
the project and the Runner target, for every scheme (`Xcode` UI, or the
equivalent line in each `XCBuildConfiguration` in `project.pbxproj`).

Without it, `wake_word_init` and the rest of the exports `force_link()` exists
to protect (see above) get stripped anyway — but **only** in an archived build
(`flutter build ipa`, `xcodebuild archive`, a TestFlight/App Store pipeline,
Fastlane's `gym`). Xcode's "Strip Linked Product" step only runs on an install
action, not a plain build, so `flutter build ios/macos --release` on its own
will not catch a missing setting here — the failure is production-only, and
looks identical to a permission or hardware problem (`WakeWordListener` logs
`engine init failed` and the health check just keeps retrying — see
`onEngineInitFailed` above). Every platform target in `example/` already has
this set; a consumer's own app does not inherit it and has to add it itself.

## Permissions

The Android manifest declares `RECORD_AUDIO` and it merges into the host app.
iOS and macOS hosts still need their own usage-description entries
(`NSMicrophoneUsageDescription`, plus the audio-input entitlement on macOS).

## License

Proprietary — internal use only.
