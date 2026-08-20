import AVFoundation
import Flutter
import Foundation

// The wake-word runtime is compiled into the host app through this pod. Binding
// the C symbol here — rather than in the app's own AppDelegate, as an earlier
// revision did — keeps force-linking an internal detail of the package: the
// registrant already references this plugin class, which pulls in the object
// file that carries the wake_word_* exports and keeps the linker from dead-
// stripping them, so `dart:ffi` can find them via DynamicLibrary.process().
@_silgen_name("voice_wakeword_force_link")
func voice_wakeword_force_link()

// `FlutterError` is a plain Objective-C `NSObject` subclass, not `NSError`,
// so Swift does not bridge it to `Error` automatically — required to hand one
// to the `Result<_, Error>` completions the generated Pigeon protocol below
// expects, the same way the raw-channel code below already constructs and
// throws these.
extension FlutterError: Error {}

public final class VoiceCommandKitPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, WakeWordAudioHostApi {
    private static let eventChannelName = "voice_command_kit/pcm"
    private static let targetSampleRate = 16_000.0

    private var audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private var audioConverter: AVAudioConverter?
    private var eventSink: FlutterEventSink?
    private var isListening = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        voice_wakeword_force_link()

        let instance = VoiceCommandKitPlugin()
        let eventChannel = FlutterEventChannel(
            name: eventChannelName,
            binaryMessenger: registrar.messenger()
        )

        WakeWordAudioHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
        eventChannel.setStreamHandler(instance)
    }

    public func checkOrRequestPermission(completion: @escaping (Result<Bool, Error>) -> Void) {
        requestMicrophonePermission { error in
            completion(.success(error == nil))
        }
    }

    public func startListening(completion: @escaping (Result<Void, Error>) -> Void) {
        requestMicrophonePermission { [weak self] permissionError in
            guard let self else { return }
            if let permissionError {
                completion(.failure(permissionError))
                return
            }

            do {
                try self.startEngineIfNeeded()
                completion(.success(()))
            } catch {
                completion(.failure(FlutterError(
                    code: "VOICE_AUDIO_START_FAILED",
                    message: error.localizedDescription,
                    details: nil
                )))
            }
        }
    }

    public func stopListening(completion: @escaping (Result<Void, Error>) -> Void) {
        stopListening()
        completion(.success(()))
    }

    public func isListening(completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(isListening))
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

    private func requestMicrophonePermission(completion: @escaping (FlutterError?) -> Void) {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                completion(nil)
            case .denied:
                completion(FlutterError(
                    code: "VOICE_MIC_PERMISSION_DENIED",
                    message: "Microphone permission denied.",
                    details: nil
                ))
            case .undetermined:
                AVAudioApplication.requestRecordPermission { granted in
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
        } else {
            switch audioSession.recordPermission {
            case .granted:
                completion(nil)
            case .denied:
                completion(FlutterError(
                    code: "VOICE_MIC_PERMISSION_DENIED",
                    message: "Microphone permission denied.",
                    details: nil
                ))
            case .undetermined:
                audioSession.requestRecordPermission { granted in
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
    }

    private func startEngineIfNeeded() throws {
        if isListening {
            return
        }

        // 1. Configure and activate the audio session FIRST to ensure input hardware resources are allocated.
        try audioSession.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try audioSession.setPreferredSampleRate(Self.targetSampleRate)
        try audioSession.setActive(true, options: [])

        // 2. NOW recreate and setup the audio engine.
        // Recreate the engine for each start so repeated stop/start cycles on iOS
        // do not retain stale input-node/tap state from the previous session.
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "VoiceCommandKitPlugin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM output format."]
            )
        }

        audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        guard audioConverter != nil else {
            throw NSError(
                domain: "VoiceCommandKitPlugin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."]
            )
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer, outputFormat: outputFormat)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
    }

    private func processInputBuffer(_ inputBuffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let audioConverter, let eventSink else {
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
        let status = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
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
        }
        audioConverter = nil
        isListening = false

        do {
            try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
        }
    }
}
