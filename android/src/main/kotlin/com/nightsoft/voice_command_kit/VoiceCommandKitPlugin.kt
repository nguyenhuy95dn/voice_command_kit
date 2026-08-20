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
import io.flutter.plugin.common.PluginRegistry
import kotlin.math.max

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
    WakeWordAudioHostApi,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private var appContext: Context? = null
    private var activity: Activity? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var pendingPermissionCallback: ((Result<Boolean>) -> Unit)? = null

    @Volatile
    private var isRecording = false
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        appContext = binding.applicationContext
        WakeWordAudioHostApi.setUp(binding.binaryMessenger, this)
        eventChannel = EventChannel(binding.binaryMessenger, PCM_EVENT_CHANNEL)
        eventChannel?.setStreamHandler(this)
    }

    /**
     * Mirrors the iOS/macOS/Windows contract: a single call that returns whether
     * the microphone may be used, showing the system prompt if it has not been
     * answered yet. Keeping this in the package means a consumer does not need a
     * permission plugin of its own just to use the wake word.
     */
    override fun checkOrRequestPermission(callback: (Result<Boolean>) -> Unit) {
        val context = appContext
        if (context == null) {
            callback(Result.failure(FlutterError("CONTEXT_NOT_AVAILABLE", "Application context is not available")))
            return
        }

        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            callback(Result.success(true))
            return
        }

        val act = activity
        if (act == null) {
            // No activity to host the system dialog (e.g. asked from a
            // background isolate). Report the current state rather than
            // stranding the caller's future.
            callback(Result.success(false))
            return
        }

        // A second request while one is in flight would strand the first
        // result; the caller is told to wait for the answer it already has
        // coming.
        if (pendingPermissionCallback != null) {
            callback(Result.success(false))
            return
        }

        pendingPermissionCallback = callback
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

        val pending = pendingPermissionCallback ?: return true
        pendingPermissionCallback = null
        pending(
            Result.success(
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            )
        )
        return true
    }

    override fun startListening(callback: (Result<Unit>) -> Unit) {
        val context = appContext
        if (context == null) {
            callback(Result.failure(FlutterError("CONTEXT_NOT_AVAILABLE", "Application context is not available")))
            return
        }

        if (isRecording) {
            callback(Result.success(Unit))
            return
        }

        val permissionGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (!permissionGranted) {
            callback(Result.failure(FlutterError("RECORD_AUDIO_DENIED", "Microphone permission is not granted")))
            return
        }

        val minBufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBufferSize <= 0) {
            callback(Result.failure(FlutterError("AUDIO_RECORD_CONFIG", "Invalid AudioRecord buffer size: $minBufferSize")))
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
            callback(Result.failure(FlutterError("AUDIO_RECORD_INIT", "AudioRecord failed to initialize")))
            return
        }

        audioRecord = recorder
        isRecording = true
        recorder.startRecording()
        recordingThread = Thread(
            { readLoop(recorder) },
            "VoiceCommandKitAudioThread"
        ).also { it.start() }
        callback(Result.success(Unit))
    }

    override fun stopListening(callback: (Result<Unit>) -> Unit) {
        stopListeningInternal()
        callback(Result.success(Unit))
    }

    override fun isListening(callback: (Result<Boolean>) -> Unit) {
        callback(Result.success(isRecording))
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
        WakeWordAudioHostApi.setUp(binding.binaryMessenger, null)
        eventChannel?.setStreamHandler(null)
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
