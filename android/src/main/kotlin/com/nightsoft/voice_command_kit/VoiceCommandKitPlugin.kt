package com.nightsoft.voice_command_kit

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlin.math.max

private const val METHOD_CHANNEL = "voice_command_kit/audio"
private const val PCM_EVENT_CHANNEL = "voice_command_kit/pcm"
private const val SAMPLE_RATE = 16000
private const val FRAME_SAMPLES = 1280
private const val FRAME_BYTES = FRAME_SAMPLES * 2
private const val RECORD_AUDIO_REQUEST_CODE = 6401

/**
 * Captures 16 kHz mono Int16 PCM from the microphone and streams it to Dart,
 * where the wake-word engine consumes it over FFI.
 *
 * The channel contract is identical on every platform this package supports —
 * see the package README.
 */
class VoiceCommandKitPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private var appContext: Context? = null
    private var activity: Activity? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    @Volatile
    private var isRecording = false
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, PCM_EVENT_CHANNEL)
        eventChannel?.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkOrRequestPermission" -> checkOrRequestPermission(result)
            "startListening" -> startListening(result)
            "stopListening" -> {
                stopListeningInternal()
                result.success(null)
            }
            "isListening" -> result.success(isRecording)
            else -> result.notImplemented()
        }
    }

    /**
     * Mirrors the iOS/macOS/Windows contract: a single call that returns whether
     * the microphone may be used, showing the system prompt if it has not been
     * answered yet. Keeping this in the package means a consumer does not need a
     * permission plugin of its own just to use the wake word.
     */
    private fun checkOrRequestPermission(result: MethodChannel.Result) {
        val context = appContext
            ?: return result.error("CONTEXT_NOT_AVAILABLE", "Application context is not available", null)

        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }

        val act = activity
        if (act == null) {
            // No activity to host the system dialog (e.g. asked from a
            // background isolate). Report the current state rather than
            // stranding the caller's future.
            result.success(false)
            return
        }

        // A second request while one is in flight would strand the first
        // result; the caller is told to wait for the answer it already has
        // coming.
        if (pendingPermissionResult != null) {
            result.success(false)
            return
        }

        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            act,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            RECORD_AUDIO_REQUEST_CODE
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != RECORD_AUDIO_REQUEST_CODE) return false

        val pending = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        pending.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        )
        return true
    }

    private fun startListening(result: MethodChannel.Result) {
        val context = appContext
            ?: return result.error("CONTEXT_NOT_AVAILABLE", "Application context is not available", null)

        if (isRecording) {
            result.success(null)
            return
        }

        val permissionGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (!permissionGranted) {
            result.error("RECORD_AUDIO_DENIED", "Microphone permission is not granted", null)
            return
        }

        val minBufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBufferSize <= 0) {
            result.error("AUDIO_RECORD_CONFIG", "Invalid AudioRecord buffer size: $minBufferSize", null)
            return
        }

        val bufferSize = max(minBufferSize, FRAME_BYTES * 4)
        val recorder = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize
        )

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            result.error("AUDIO_RECORD_INIT", "AudioRecord failed to initialize", null)
            return
        }

        audioRecord = recorder
        isRecording = true
        recorder.startRecording()
        recordingThread = Thread(
            { readLoop(recorder) },
            "VoiceCommandKitAudioThread"
        ).also { it.start() }
        result.success(null)
    }

    private fun readLoop(recorder: AudioRecord) {
        while (isRecording) {
            val frame = ByteArray(FRAME_BYTES)
            val bytesRead = recorder.read(frame, 0, frame.size)
            if (bytesRead <= 0) {
                continue
            }

            val payload = if (bytesRead == frame.size) frame else frame.copyOf(bytesRead)
            mainHandler.post {
                if (isRecording && appContext != null) {
                    try {
                        eventSink?.success(payload)
                    } catch (e: RuntimeException) {
                        stopListeningInternal()
                    } catch (e: Exception) {
                        stopListeningInternal()
                    }
                }
            }
        }
    }

    private fun stopListeningInternal() {
        isRecording = false
        recordingThread?.interrupt()
        recordingThread = null

        audioRecord?.let { recorder ->
            try {
                recorder.stop()
            } catch (_: IllegalStateException) {
            }
            recorder.release()
        }
        audioRecord = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        stopListeningInternal()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
        appContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}
