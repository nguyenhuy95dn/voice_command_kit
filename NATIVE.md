# Wake word native engine

Shared C++ wake-word detection core (`src/voice_wakeword.cpp`, ONNX Runtime:
mel-spectrogram → embedding → per-model classifier), exposed through the plain
C API in `src/include/voice_wakeword.h`:

```c
int  wake_word_init(mel_model_path, embedding_model_path, classifier_model_paths, num_classifiers);
int  wake_word_process_pcm(pcm, sample_count, out_scores, max_scores);
void wake_word_reset();
void wake_word_close();
const char* wake_word_last_error();
```

Dart calls this directly via FFI (`lib/src/engine/wake_word_bindings.dart` →
`WakeWordEngine`), so `wake_word_process_pcm` always expects **16 kHz mono Int16
PCM**, regardless of platform.

There is one more export, `voice_wakeword_force_link()`. It does nothing useful
at runtime: it exists so the Apple plugins can reference it and stop the linker
dead-stripping the `wake_word_*` symbols out of the host binary, which
`DynamicLibrary.process()` then has to find.

## One C++ source, four platform wrappers

Each platform directory holds both halves: the build that produces the engine,
and the plugin that feeds it audio. Every wrapper compiles the *same*
`src/voice_wakeword.cpp` — the Apple ones through a one-line `#include` shim, so
CocoaPods only sees files inside its own pod directory.

| Platform | Native lib build | Audio capture (feeds PCM in) |
|---|---|---|
| Android | `android/src/main/cpp/CMakeLists.txt` → `libvoice_wakeword.so`, loaded via `DynamicLibrary.open` | `VoiceCommandKitPlugin.kt` — `AudioRecord` |
| iOS | `ios/Classes/voice_wakeword_ios.cpp` via the pod, statically linked (`DynamicLibrary.process()`); simulator gets a stub instead, since there is no ONNX Runtime slice for it | `ios/Classes/VoiceCommandKitPlugin.swift` — `AVAudioEngine` + `AVAudioSession` |
| macOS | `macos/Classes/voice_wakeword_macos.cpp` via the pod; links `onnxruntime.framework` from `macos/Frameworks/`, statically linked (`DynamicLibrary.process()`) | `macos/Classes/VoiceCommandKitPlugin.swift` — `AVAudioEngine`, **no** `AVAudioSession` (macOS doesn't have one) |
| Windows | `windows/CMakeLists.txt` + `windows/onnxruntime/` → `voice_wakeword.dll`, bundled next to the exe and loaded via `DynamicLibrary.open` | `windows/voice_command_kit_plugin.cpp` — WASAPI |

Every platform's audio-capture plugin exposes the **same** Flutter channel
contract, consumed uniformly by `wake_word_audio_channel.dart`:
- Method channel `voice_command_kit/audio`: `checkOrRequestPermission` /
  `startListening` / `stopListening` / `isListening`.
- Event channel `voice_command_kit/pcm`: raw mono 16 kHz Int16 PCM chunks.
- Event channel `voice_command_kit/device_events`: the string
  `"defaultInputChanged"`, emitted when the microphone being captured from
  changes. **Implemented on macOS only so far** — the Dart side ignores the
  `MissingPluginException` the other platforms produce, so any of them picks
  this up simply by starting to emit, with no Dart change. See below for what
  the event means and why the payload carries no detail.

## Rosetta translation crashes the ONNX engine (macOS)

`macos/Frameworks/onnxruntime.framework` is a fat `x86_64`/`arm64` static
archive; the linker picks whichever slice matches the app's build
architecture. If the app ends up running the `x86_64` slice under Rosetta 2
on Apple Silicon — most commonly by selecting Xcode's **"My Mac (Rosetta)"**
run destination, but also possible for a genuinely Intel-only build —
`g_ort->Run()` traps with `EXC_BAD_INSTRUCTION` (illegal instruction, i.e.
`SIGILL`) the first time it actually runs inference: Rosetta does not
reliably translate the AVX2/FMA instructions onnxruntime's CPU kernels use.
This is a hardware trap, not a C++ exception or an `OrtStatus` — nothing in
`voice_wakeword.cpp` could catch it after the fact.

`wake_word_init` now checks `sysctlbyname("sysctl.proc_translated", ...)`
*before* touching ONNX Runtime at all and fails cleanly (`return 0` +
`set_error`, same contract as every other init failure) instead of letting
the first inference crash the process. On the Dart side this surfaces as an
ordinary `wake_word_init failed` `StateError` from `WakeWordBindings.init`,
already handled by `WakeWordListener._startInternal`'s catch block exactly
like a missing model file — voice control just doesn't start, no crash.

Real end users on real Apple Silicon Macs never hit this (there is no
Rosetta translation involved). Run the app on the **native "My Mac"**
destination, not "My Mac (Rosetta)", to get real wake-word inference while
developing on Apple Silicon.

## KleidiAI SME kernel crash, running fully native (macOS, Apple Silicon)

A second, unrelated crash with the exact same symptom (`g_ort->Run()` traps
with `EXC_BAD_INSTRUCTION`) shows up even with no Rosetta involved at all —
confirmed by the crashing frame itself: `kai_run_lhs_pack_f32p2vlx1_f32_sme`,
a pure-arm64 KleidiAI GEMM kernel, which cannot appear in a Rosetta-translated
x86_64 process.

ONNX Runtime's MLAS backend ships a KleidiAI integration that feature-detects
ARM SME (Scalable Matrix Extension) and dispatches SME-specific kernels for
float32 matmuls when it believes SME is usable. On this Apple Silicon
hardware that detection is a false positive: the process has no real usable
SME execution state, so the first SME kernel call traps — same class of
"hardware trap, not catchable" problem as the Rosetta case above.

Unlike the Rosetta case, this one isn't "don't do the thing that's already
broken" — it's a real, documented ONNX Runtime session option:
`AddSessionConfigEntry(options, kOrtSessionOptionsMlasDisableKleidiAi, "1")`
(`onnxruntime_session_options_config_keys.h`) forces MLAS back onto its
non-SME kernels, set once in `wake_word_init` right after the thread-count
options. A failure to set it is treated as non-fatal (falls through to
whatever MLAS would have done anyway) rather than aborting init, same as the
CoreML EP block below it.

## macOS audio capture: hard-won notes

macOS has no `AVAudioSession`, so `macos/Classes/VoiceCommandKitPlugin.swift` drives
`AVAudioEngine` directly and gates the microphone through `AVCaptureDevice`
authorization instead. This turned out to be the least stable part of the
whole feature — getting it crash-free took many iterations. Recorded here so
the same crashes aren't rediscovered from scratch.

### The bugs, in the order they were found

1. **0-channel input format right after permission grant.** Right after mic
   access is first authorized, CoreAudio can briefly report a format with a
   valid sample rate but 0 channels before the HAL finishes exposing the
   route. `installTap` throws an uncatchable `NSException` for an invalid
   format. Fixed by validating `sampleRate > 0 && channelCount > 0` and
   retrying (10× / 100ms) *before* calling `installTap`, never after.

2. **"Failed to create tap due to format mismatch" / `"format.sampleRate ==
   inputHWFormat.sampleRate"` CoreAudio assertion.** Chased for a long time
   as ordering/timing bugs — tried calling `audioEngine.prepare()` before
   reading `inputNode.outputFormat(forBus:)` instead of after (Apple's docs
   suggest the pre-`prepare()` format can be provisional), tried re-reading
   the format immediately before `installTap` to shrink the race window,
   tried forcing the default input/output device's nominal sample rate to
   match via CoreAudio `AudioObjectSetPropertyData`. **None of it was the
   real fix** — see (3). The shipped code does *not* reorder `prepare()`
   (still called right before `audioEngine.start()`, after `installTap`,
   same as the original) and does *not* touch device sample rates; once (3)
   was fixed, these crashes stopped happening — for a long time.

   **Incomplete — see (10).** "Stopped happening" turned out to mean
   "stopped happening for the *no-mic* trigger," not "can't happen." The
   exact same error message came back under a different trigger: the default
   input device changing (e.g. a headset switching off) in the narrow window
   between reading `inputFormat` and calling `installTap`, which (3)'s guard
   does nothing to close.

3. **No microphone at all (Mac mini, no built-in mic) — the real root
   cause.** All of (2)'s crashes, plus the 0-channel one in (1), turned out
   to be different-looking symptoms of the same thing: `inputNode` had no
   real hardware behind it at all, so CoreAudio was returning
   garbage/inconsistent state for a nonexistent device — no amount of
   reordering or re-reading the format on the Swift side could fix that,
   because the values being read were never going to be meaningful. Confirmed
   by every one of these crashes disappearing once a Bluetooth headset was
   connected (making `inputNode` back a real device). Fixed with a fast,
   clean guard: `AVCaptureDevice.default(for: .audio) != nil` checked
   *before* touching `AVAudioEngine` at all — no device, no crash, just a
   clean `FlutterError`.

   A structural alternative was also evaluated and **not** used:
   `AVCaptureSession` + `AVCaptureAudioDataOutput`, a completely different
   capture pipeline that sidesteps `installTap`'s format validation
   entirely. It was implemented once, then reverted once the "no mic" root
   cause was found, since the original `AVAudioEngine` approach works fine
   whenever real hardware is present — no need for the bigger rewrite.

4. **Retrying without a mic → hardware hot-plug.** Once (3) was handled by
   *failing* cleanly, the app still needed to notice when a mic/headset gets
   plugged in later:
   - `WakeWordListener.isRunning` (distinct from `isHealthy`, which
     treats "not running" as fine when intentionally stopped) lets
     `VoicePipeline`'s existing ~10s health-check timer retry
     `start()` whenever it should be running but isn't — a safety-net poll.
   - For near-real-time reaction, the plugin also observed
     `AVCaptureDevice.wasConnectedNotification` /
     `wasDisconnectedNotification` (filtered to `.audio` devices) and pushed
     `"connected"`/`"disconnected"` over the new `voice_command_kit/device_events`
     event channel; `VoicePipeline` reacted by immediately re-running
     the health check instead of waiting for the next poll.
     **Superseded — see (9).** These notifications answer "did *a* device
     appear or vanish", not "did *ours* change": they fire for devices the
     engine never used, and stay silent when the user picks a different input
     in System Settings without plugging anything in.

5. **Data race: `objc_msgSend` EXC_BAD_ACCESS in the `installTap` callback.**
   The tap closure runs on a CoreAudio render thread, not the main thread.
   It used to read `self.audioConverter` — but that property gets
   reassigned/nil'd from the main thread on every start/stop, which now
   happens rapidly under hot-plug. A tap invocation already in flight when
   the main thread nil'd the converter was calling a method on an object
   that had just been deallocated (the sole strong reference). Fixed by
   capturing the specific `AVAudioConverter` instance directly in the tap
   closure (same pattern `outputFormat` already used) and passing it into
   `processInputBuffer` as a parameter, instead of reading the shared
   mutable property from a background thread.

6. **Thread-unsafety in the hot-plug/config-change notification handlers.**
   `NotificationCenter` notifications (`AVCaptureDevice.wasConnectedNotification`,
   `.AVAudioEngineConfigurationChange`) aren't guaranteed to fire on the main
   thread, but every other read/write of `audioEngine`/`isListening` in this
   class happens on main. All the handlers now hop to
   `DispatchQueue.main.async` before touching any shared state.

7. **`AVAudioEngineConfigurationChange` — tearing down the crashed device's
   engine safely.** `AVCaptureDevice.wasDisconnectedNotification` alone only
   *informs* Dart; it doesn't stop the engine, so a tap could keep running on
   hardware that had already vanished until Dart's round trip called
   `stopListening()` — a crash window. `AVAudioEngine` posts
   `.AVAudioEngineConfigurationChange` the instant *its own* hardware
   configuration changes; the plugin now observes it and calls
   `stopListening()` synchronously and immediately in response, before
   notifying Dart.
   **Superseded — see (9).** The synchronous teardown survives; the
   notification that triggered it does not. Note this entry says a tap
   *could* keep running and calls it a crash window: unlike (5) and (8), it
   records a hazard reasoned about rather than a crash observed.

8. **Recreating `AVAudioEngine()` too soon after any hardware change.**
   CoreAudio's HAL AudioUnit teardown for a stopped engine is asynchronous —
   `stop()`/`reset()` returning doesn't guarantee the old engine's
   `AVAudioIOUnit` render queue has drained. Likewise, a just-connected
   device isn't necessarily fully registered in AVFoundation's device list
   the instant its "connected" notification fires. Recreating
   `AVAudioEngine()` / calling `AVCaptureDevice.default(for:)` too soon after
   *either* kind of change crashed with `EXC_BAD_ACCESS` — once on the old
   engine's `AVAudioIOUnit (serial)` queue (an already-enqueued callback from
   the old engine racing the new one), once on the main thread inside
   `startEngineIfNeeded` itself on the very first start attempt right after a
   "connected" notification (no prior teardown to have gated on). Fixed with
   `lastHardwareChangeAt`, updated from *any* of: our own `stopListening()`,
   a device-connected notification, or a device-disconnected notification —
   `startEngineIfNeeded` waits out a 300ms settle window from whichever of
   those happened most recently before creating a new engine.
   *(Still true after (9); the sources feeding `lastHardwareChangeAt` are now
   our own `stopListening()` and `handleDefaultInputDeviceChanged()`. The
   latter records it unconditionally, not only when an engine was actually
   running — a device change landing while stopped, e.g. after a start that
   failed for lack of a microphone, must still gate the next start.)*

9. **Three notifications, none of which answered the actual question.** The
   engine binds to the **system default input device** and this plugin never
   selects a device explicitly. So the only question worth observing is
   *"has the default input device changed?"* — and none of (4)/(7) asked it:

   - `.AVAudioEngineConfigurationChange` has a **spurious variant**:
     AVAudioEngine posts it once right after a fresh engine's `start()` as
     CoreAudio settles the input format, with no hardware change at all.
     Tearing down on that post produced a self-sustaining stop/start loop
     that raced the previous AudioUnit's teardown and threw `OSStatus -10877`
     (`kAudioUnitErr_InvalidElement`). Suppressing it needed a 750ms grace
     period keyed on the clock — which then swallowed *real* device changes
     that happened to land inside the window. It also fires for output-only
     changes (plugging in speakers or an HDMI display), tearing down a
     perfectly healthy capture.
   - `AVCaptureDevice.wasConnected/wasDisconnected` fire for devices the
     engine never used, and stay silent when the user picks a different input
     in System Settings without plugging anything in.

   All three were replaced by a single CoreAudio property listener on
   `kAudioHardwarePropertyDefaultInputDevice`. It is a system-level fact with
   **no spurious variant**, so the 750ms grace period and `lastEngineStartAt`
   were deleted outright rather than re-homed. Coverage:

   | Situation | Fires? |
   |---|---|
   | Bluetooth headset connects and macOS switches input to it | yes |
   | Bluetooth headset connects, macOS does *not* switch | no — correct, the system mic is unchanged |
   | User changes input in System Settings | yes |
   | Active mic unplugged (another remains) | yes, falls back |
   | Active mic unplugged (none left) | yes → `kAudioObjectUnknown` |
   | No mic at all, one is plugged in | yes |
   | A device that wasn't being used is unplugged | no — correct, irrelevant |

   The handler does exactly two unconditional things: `stopListening()` in
   place (the tap may be on hardware that just vanished, and a round trip to
   Dart is too slow to be safe), then emit `"defaultInputChanged"`. **No
   comparison, no heuristic remains natively.** Dart owns the recovery
   decision — and since the engine is already stopped when the event lands,
   that decision is unconditional too: comparing device identity to skip a
   restart would leave the listener dead until the next health-check tick.

   This is also the first contract here that ports cleanly: Windows exposes
   the same signal as `IMMNotificationClient::OnDefaultDeviceChanged`.

   **Not yet verified on hardware** (log the `NSLog` device UIDs to settle
   each): whether macOS auto-switches the default input to a connecting
   Bluetooth headset — if it does not, connecting one will *correctly* change
   nothing, and forcing capture onto it would require setting
   `kAudioOutputUnitProperty_CurrentDevice` on the input node's AudioUnit;
   and whether a 3.5 mm jack transition changes the default *device* at all,
   or only that device's data source (in which case it does not fire).

10. **"Format mismatch," for real this time: a device change landing between
    reading the format and calling `installTap`.** (2) was declared fixed
    once (3)'s no-mic guard shipped, but the same
    `"Failed to create tap due to format mismatch"` crash came back —
    triggered by turning a headset off, not by having no microphone at all.
    Sequence: `inputFormat = inputNode.outputFormat(forBus: 0)` reads a
    valid format (say the headset's, 2ch/44.1kHz); before the very next line,
    `installTap`, actually runs, CoreAudio finishes switching the default
    input to the built-in mic; `installTap(format: inputFormat)` is now
    asking for a format that no longer matches what the hardware is actually
    running, and throws the same uncatchable `NSException` as (1)'s
    0-channel case. (9)'s 300ms settle window doesn't help — it only guards
    the time *before* `startEngineIfNeeded` begins, not the handful of
    statements *inside* it, and a device switch is a real-time hardware
    event that doesn't wait for Swift to finish a run-loop turn.

    No amount of re-reading the format closer to `installTap` closes this
    window — it can only ever be shrunk, not eliminated, because the
    hardware event and the Swift statements are on independent clocks. Fixed
    structurally instead: `installTap` is now called with `format: nil`.
    Per Apple's docs a nil format makes the tap adopt the bus's *actual*
    format at the instant the call executes, atomically, which by
    construction cannot mismatch itself — there is no longer a format value
    for a race to go stale.

    That removes the one thing `AVAudioConverter`'s `from:` format used to be
    read from ahead of time, so the converter moved from being built once on
    the main thread (then captured into the tap closure per (5)) to being
    built lazily *inside* the closure, on the first callback and again
    whenever a later buffer's format changes underneath it. It is **not**
    stored on `self`: `tapConverter`/`tapConverterFormat` are local variables
    captured by the closure, touched only by the CoreAudio render thread that
    invokes it — never by the main thread — so (5)'s use-after-free hazard
    (a converter reassigned/nil'd on `self` from main while the render thread
    was still reading it) cannot recur here; there is no shared mutable
    property left to race over.

### Current design (end state)

```
settle 300ms since last hardware change (our stop, or a default-input change)
        ↓
AVCaptureDevice.default(for: .audio) != nil?  — fail fast, no crash, if not
        ↓
AVAudioEngine() created fresh (once per start, not per retry attempt)
        ↓
read inputNode.outputFormat(forBus: 0) — sanity check only, see below
        ↓
retry (10× / 100ms) if 0-channel/invalid — permission-grant settle window
        ↓
installTap(format: nil — adopts the bus's actual format atomically, can't mismatch)
        ↓
prepare() → start()
        ↓
tap closure builds/rebuilds its own local AVAudioConverter from each
buffer's real format → 16 kHz mono Int16 → voice_command_kit/pcm event channel
```

Plus, the one observer left:

```
kAudioHardwarePropertyDefaultInputDevice changed   (listener block on DispatchQueue.main)
        ↓
record lastHardwareChangeAt  →  stopListening()  →  send "defaultInputChanged"
        ↓
Dart: stop() → resumeBackgroundListener()   (~10s health check remains the backstop)
```

If a future crash shows up on the `AVAudioIOUnit (serial)` queue or as
`objc_msgSend` on a garbage address again, start by checking (a) whether a
new shared mutable property got introduced that's read from the tap
callback, and (b) whether the 300ms settle window needs lengthening for
whatever hardware exhibited it.

Known gap, deliberately left: `stopListening()` does not cancel the
`DispatchQueue.main.asyncAfter` retry chain that `startEngineIfNeeded`
schedules, so a start already in flight can still bring an engine up after a
stop. Fixing it means a generation token — unrelated to the device-event
work above.
