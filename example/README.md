# voice_command_kit example

A tiny app that turns a light on and off by voice, to show what a consumer of
this package actually has to write: a `VoicePipelineConfig`, an
`availableCommands` callback, and an `onCommand` callback. Roughly forty lines
of the app are the integration; the rest is UI.

## Running it

The package ships no models, so supply four ONNX files under
`example/assets/models/` before running:

| File | What it is |
|---|---|
| `melspectrogram.onnx` | generic — audio to mel frames |
| `embedding_model.onnx` | generic — mel frames to embeddings |
| `hey_sunny.onnx` | the wake phrase, "Hey Sunny" |
| `turn_on.onnx`, `turn_off.onnx` | one classifier per command |

The two generic models come from
[openWakeWord](https://github.com/dscripka/openWakeWord); the classifiers are
trained per phrase — see `../doc/TRAINING_MODELS.md`. On Android, iOS and
macOS the command classifiers are optional — speech-to-text matches the
`phrases` instead — but the wake word always needs a model.

```bash
flutter run            # add -d windows / -d macos as needed
```

Then press **Start listening**, say "Hey Sunny", and follow it with
"turn on". The log pane shows every stage the pipeline goes through.
