# Training a wake word or command model

`voice_command_kit` ships no models. This is how to produce one: a complete
walkthrough of training a custom classifier with **livekit-wakeword**, using
"Motion Future" as the worked example.

The result is the `classifier` half of a `WakeWordModel` or `VoiceCommand`; the
generic melspectrogram and embedding models come from
[openWakeWord](https://github.com/dscripka/openWakeWord) and are not trained per
phrase.

## 1. Setup Environment (macOS)

```bash
# 1. Create virtual environment
python3 -m venv livekit-venv

# 2. Activate venv
source livekit-venv/bin/activate

# 3. Upgrade pip
pip install --upgrade pip

# 4. Install livekit-wakeword
pip install "livekit-wakeword[train,eval,export]"

# 5. Install system dependencies
brew install espeak-ng ffmpeg portaudio sox
```

## 2. Create Config File (`motion_future.yaml`)

```yaml
model_name: motion_future
target_phrases:
  - "motion future"

n_samples: 20000
model:
  model_type: conv_attention
  model_size: medium
steps: 70000
target_fp_per_hour: 0.1
```

## 3. Training Commands

```bash
# Activate environment
source livekit-venv/bin/activate

# Run full training pipeline
livekit-wakeword run motion_future.yaml

# Evaluate model
livekit-wakeword eval motion_future.yaml

# Test with microphone
livekit-wakeword test motion_future.yaml
```

## 4. Important Paths After Training

- Model: `output/motion_future/motion_future.onnx`
- Evaluation results: `output/motion_future/eval/`

## 5. Find Required Models for Flutter

```bash
# Find embedding and mel models
find livekit-venv -name "melspectrogram.onnx" 2>/dev/null
find livekit-venv -name "embedding_model.onnx" 2>/dev/null

# Copy to project folder
mkdir -p models/wakeword
cp $(find livekit-venv -name "melspectrogram.onnx" 2>/dev/null) models/wakeword/
cp $(find livekit-venv -name "embedding_model.onnx" 2>/dev/null) models/wakeword/
cp output/motion_future/motion_future.onnx models/wakeword/
```

## 6. Export to TFLite (for mobile)

```bash
livekit-wakeword export motion_future.yaml --format tflite
```

## 7. Common Issues & Fixes

- `espeak-ng not found` → `brew install espeak-ng`
- Training interrupted → Run `livekit-wakeword run motion_future.yaml` again (it resumes positive samples)
- Out of memory → Reduce `n_samples` to 12000 and `model_size: small`

## 8. Next Step: Flutter Integration

You now have:
- `melspectrogram.onnx`
- `embedding_model.onnx` 
- `motion_future.onnx`

These 3 files are needed for full wake-word detection in Flutter using ONNX Runtime.

---

**Created on:** June 2026  
**For project:** Motion Future (English support)

Let me know if you want a separate **Flutter Integration Guide**.
