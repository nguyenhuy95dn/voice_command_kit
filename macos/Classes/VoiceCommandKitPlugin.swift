import AVFoundation
import CoreAudio
import FlutterMacOS
import Foundation

// See the iOS plugin for why force-linking lives in the package rather than in
// the host app: referencing this symbol keeps the wake_word_* exports out of
// the linker's dead-strip pass so `dart:ffi` can resolve them from the process.
@_silgen_name("voice_wakeword_force_link")
func voice_wakeword_force_link()

/// Minimal `FlutterStreamHandler` for the device event channel.
/// Kept separate from `VoiceCommandKitPlugin` because a single instance set as
/// the stream handler for two different `FlutterEventChannel`s can't tell
/// `onListen`/`onCancel` apart — each channel needs its own handler.
private final class DeviceEventStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func send(_ event: String) {
        guard let eventSink else { return }
        DispatchQueue.main.async {
            eventSink(event)
        }
    }
}

/// macOS microphone capture for the wake word engine.
///
/// Mirrors the iOS plugin in this package: it exposes the same
/// `voice_command_kit/audio` method channel and `voice_command_kit/pcm` event
/// channel, streaming 16 kHz mono Int16 PCM to Dart. macOS has no
/// `AVAudioSession`, so we drive `AVAudioEngine` directly and gate the
/// microphone through `AVCaptureDevice` authorization instead.
public final class VoiceCommandKitPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let methodChannelName = "voice_command_kit/audio"
    private static let eventChannelName = "voice_command_kit/pcm"
    private static let deviceEventChannelName = "voice_command_kit/device_events"
    private static let targetSampleRate = 16_000.0

    /// The only payload sent on `deviceEventChannelName`. Kept a bare string:
    /// Dart needs no detail beyond "restart", so there is nothing to encode.
    private static let defaultInputChangedEvent = "defaultInputChanged"

    private var audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var eventSink: FlutterEventSink?
    private var isListening = false
    private let deviceEventStreamHandler = DeviceEventStreamHandler()
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    /// UID of the input device the running engine was started against. Kept for
    /// logging only — no code branches on it (see `handleDefaultInputDeviceChanged`).
    private var currentInputDeviceUID: String?

    public static func register(with registrar: FlutterPluginRegistrar) {
        voice_wakeword_force_link()

        let instance = VoiceCommandKitPlugin()
        let methodChannel = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: registrar.messenger
        )
        let eventChannel = FlutterEventChannel(
            name: eventChannelName,
            binaryMessenger: registrar.messenger
        )
        let deviceEventChannel = FlutterEventChannel(
            name: deviceEventChannelName,
            binaryMessenger: registrar.messenger
        )

        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
        deviceEventChannel.setStreamHandler(instance.deviceEventStreamHandler)
        instance.startObservingDefaultInputDevice()
    }

    deinit {
        stopObservingDefaultInputDevice()
    }

    /// The system default input device — the one `AVAudioEngine.inputNode` binds
    /// to, since this plugin never selects a device explicitly.
    private static let defaultInputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Observes *the only thing that can change which microphone we capture
    /// from*: the system default input device.
    ///
    /// This replaced three `NotificationCenter` observers, none of which
    /// answered that question:
    /// - `.AVAudioEngineConfigurationChange` has a spurious variant — AVAudioEngine
    ///   posts it once right after a fresh engine's `start()` as CoreAudio settles
    ///   the input format, with no hardware change at all. Tearing the engine down
    ///   on that post produced a self-sustaining stop/start loop (OSStatus -10877),
    ///   which needed a 750ms grace period to suppress — and that grace period in
    ///   turn swallowed *real* device changes landing inside the window. It also
    ///   fires for output-only changes, tearing down a perfectly healthy capture.
    /// - `AVCaptureDevice.wasConnected/wasDisconnected` report that *a* device
    ///   appeared or vanished, not that *ours* changed: they fire for devices we
    ///   never used, and stay silent when the user picks a different input in
    ///   System Settings without plugging anything in.
    ///
    /// The default-input property is a system-level fact with no spurious variant,
    /// and it is the exact signal every other platform also exposes (Windows
    /// `IMMNotificationClient::OnDefaultDeviceChanged`).
    private func startObservingDefaultInputDevice() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputDeviceChanged()
        }
        var address = Self.defaultInputDeviceAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        guard status == noErr else {
            NSLog("Wake Word Audio: failed to observe default input device (OSStatus %d)", status)
            return
        }
        defaultInputListenerBlock = block
    }

    private func stopObservingDefaultInputDevice() {
        guard let defaultInputListenerBlock else { return }
        var address = Self.defaultInputDeviceAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            defaultInputListenerBlock
        )
        self.defaultInputListenerBlock = nil
    }

    /// The microphone we should be capturing from has changed.
    ///
    /// Does exactly two things, unconditionally — no comparison, no heuristic:
    /// tear the engine down (the tap may be on hardware that just vanished, and
    /// a round trip to Dart is too slow to be safe), then tell Dart. Dart owns
    /// the decision of whether and when to start again; since the engine is
    /// already stopped by the time the event lands, there is nothing here worth
    /// branching on — "same device as before" would still need a restart.
    ///
    /// The listener block is registered against `DispatchQueue.main`, so this
    /// already runs on the main thread like every other mutation of
    /// `audioEngine`/`isListening` in this class.
    private func handleDefaultInputDeviceChanged() {
        let previousUID = currentInputDeviceUID ?? "none"
        let newUID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? "none"
        NSLog(
            "Wake Word Audio: default input device changed (%@ -> %@, wasListening: %@) — stopping.",
            previousUID,
            newUID,
            isListening ? "true" : "false"
        )

        // Set unconditionally, not just via stopListening() (which only records it
        // when it actually had a running engine to tear down). A device change
        // that lands while we are NOT listening — e.g. after a start that failed
        // because no microphone existed — must still gate the next start attempt
        // on the settle window below, or `startEngineIfNeeded` runs against a
        // device AVFoundation has not finished registering. That exact case
        // crashed with EXC_BAD_ACCESS on the first start after a hotplug.
        lastHardwareChangeAt = Date()
        stopListening()
        deviceEventStreamHandler.send(Self.defaultInputChangedEvent)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "checkOrRequestPermission":
            requestMicrophonePermission { error in
                result(error == nil)
            }
        case "startListening":
            startListening(result: result)
        case "stopListening":
            stopListening()
            result(nil)
        case "isListening":
            result(isListening)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        stopListening()
        return nil
    }

    private func startListening(result: @escaping FlutterResult) {
        requestMicrophonePermission { [weak self] permissionError in
            guard let self else { return }
            if let permissionError {
                result(permissionError)
                return
            }

            self.startEngineIfNeeded(attemptsLeft: Self.maxInputFormatAttempts) { error in
                if let error {
                    result(FlutterError(
                        code: "VOICE_AUDIO_START_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                } else {
                    result(nil)
                }
            }
        }
    }

    private func requestMicrophonePermission(completion: @escaping (FlutterError?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(nil)
        case .denied, .restricted:
            completion(FlutterError(
                code: "VOICE_MIC_PERMISSION_DENIED",
                message: "Microphone permission denied.",
                details: nil
            ))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(
                        granted
                            ? nil
                            : FlutterError(
                                code: "VOICE_MIC_PERMISSION_DENIED",
                                message: "Microphone permission denied.",
                                details: nil
                            )
                    )
                }
            }
        @unknown default:
            completion(FlutterError(
                code: "VOICE_MIC_PERMISSION_UNKNOWN",
                message: "Unknown microphone permission state.",
                details: nil
            ))
        }
    }

    /// Number of times to re-poll the input node's format before giving up.
    /// At 100ms apart this allows up to ~1s for CoreAudio to expose the
    /// microphone route after permission is granted (see comment below).
    private static let maxInputFormatAttempts = 10

    /// Minimum time to wait after ANY audio hardware change — our own engine
    /// teardown, or a default-input-device change, whichever happened most
    /// recently — before creating a new AVAudioEngine.
    ///
    /// CoreAudio's HAL AudioUnit teardown for a stopped engine is
    /// asynchronous (`stop()`/`reset()` returning doesn't guarantee its
    /// internal `AVAudioIOUnit` render queue has drained), and macOS's own
    /// AVFoundation device registration for a just-connected device isn't
    /// instantaneous either. Recreating `AVAudioEngine()` /
    /// `AVCaptureDevice.default(for:)` too soon after either kind of change
    /// crashed with EXC_BAD_ACCESS — once on the old engine's
    /// `AVAudioIOUnit (serial)` queue, once inside this very function on the
    /// main thread when it was the very *first* start attempt after a hotplug
    /// (so there had been no prior teardown to gate on). Recording the change
    /// in `handleDefaultInputDeviceChanged` too, not just in our own
    /// `stopListening()`, covers both.
    private static let hardwareSettleInterval: TimeInterval = 0.3

    private var lastHardwareChangeAt: Date?

    private func startEngineIfNeeded(attemptsLeft: Int, completion: @escaping (Error?) -> Void) {
        if isListening {
            completion(nil)
            return
        }

        if let lastHardwareChangeAt {
            let elapsed = Date().timeIntervalSince(lastHardwareChangeAt)
            if elapsed < Self.hardwareSettleInterval {
                DispatchQueue.main.asyncAfter(deadline: .now() + (Self.hardwareSettleInterval - elapsed)) { [weak self] in
                    self?.startEngineIfNeeded(attemptsLeft: attemptsLeft, completion: completion)
                }
                return
            }
        }

        // Machines with no built-in microphone and nothing plugged in (e.g. a
        // Mac mini with no external mic/headset connected) report NO audio
        // capture device at all. AVAudioEngine's inputNode still exists as an
        // object in that case, but has no real hardware to back it — its
        // outputFormat(forBus:)/installTap calls return garbage/inconsistent
        // state that crashes the process in several different ways (0-channel
        // format, "format mismatch", "sampleRate == inputHWFormat.sampleRate")
        // depending on exactly what CoreAudio does for a nonexistent device.
        // Check for a real device FIRST and fail cleanly instead of touching
        // AVAudioEngine at all when there isn't one. Plugging a mic/headset in
        // later re-runs this via handleDefaultInputDeviceChanged (a device
        // appearing where there was none changes the default input), with Dart's
        // periodic health check as the backstop.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            completion(NSError(
                domain: "VoiceCommandKitPlugin",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No microphone is connected."]
            ))
            return
        }

        // Recreate the engine for each start so repeated stop/start cycles do not
        // retain stale input-node/tap state from the previous session.
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Right after microphone access is first granted, CoreAudio can briefly
        // report a format with a valid sample rate but 0 channels, before the HAL
        // finishes exposing the newly-authorized input route. AVAudioEngine's
        // installTap throws an Objective-C NSException (not a Swift `Error`) for
        // an invalid format, which cannot be caught and crashes the whole process
        // — so we must validate and retry *before* calling installTap rather than
        // attempting to catch a failure from it.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.startEngineIfNeeded(attemptsLeft: attemptsLeft - 1, completion: completion)
                }
            } else {
                completion(NSError(
                    domain: "VoiceCommandKitPlugin",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No active microphone input available."]
                ))
            }
            return
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            completion(NSError(
                domain: "VoiceCommandKitPlugin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM output format."]
            ))
            return
        }

        audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        guard let converter = audioConverter else {
            completion(NSError(
                domain: "VoiceCommandKitPlugin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."]
            ))
            return
        }

        inputNode.removeTap(onBus: 0)
        // Capture `converter` directly (like `outputFormat` below) rather than
        // reading the shared `self.audioConverter` property inside the tap
        // callback. The tap closure runs on a CoreAudio render thread, not the
        // main thread — `self.audioConverter` gets reassigned/nil'd from the
        // main thread on every start/stop (now happening rapidly on mic
        // hot-plug), and a tap invocation already in flight when that happens
        // was reading a converter the main thread had just deallocated: a
        // use-after-free (EXC_BAD_ACCESS in objc_msgSend). Capturing the
        // specific instance keeps it alive for as long as this closure exists,
        // independent of whatever `self.audioConverter` currently points to.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer, converter: converter, outputFormat: outputFormat)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            currentInputDeviceUID = AVCaptureDevice.default(for: .audio)?.uniqueID
            NSLog("Wake Word Audio: engine started on input device %@", currentInputDeviceUID ?? "unknown")
            completion(nil)
        } catch {
            completion(error)
        }
    }

    private func processInputBuffer(_ inputBuffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        guard let eventSink else {
            return
        }

        let capacity = AVAudioFrameCount(
            Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate
        ) + 64
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            return
        }

        var converted = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if converted {
                outStatus.pointee = .noDataNow
                return nil
            }

            converted = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || conversionError != nil || outputBuffer.frameLength == 0 {
            return
        }

        guard let channelData = outputBuffer.int16ChannelData else {
            return
        }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: channelData.pointee, count: byteCount)
        DispatchQueue.main.async {
            eventSink(FlutterStandardTypedData(bytes: data))
        }
    }

    private func stopListening() {
        if isListening {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()
            lastHardwareChangeAt = Date()
        }
        audioConverter = nil
        isListening = false
        currentInputDeviceUID = nil
    }
}
