package ai.vaachak.vaachak_app

import android.app.ActivityManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.os.StatFs
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    private val playbackGeneration = AtomicInteger(0)
    private val audioLock = Any()
    private var playingTrack: AudioTrack? = null

    private fun stopPlayback() {
        playbackGeneration.incrementAndGet()
        synchronized(audioLock) {
            try {
                playingTrack?.pause()
                playingTrack?.flush()
            } catch (_: IllegalStateException) {
                // A failed/uninitialized track is released by its owning worker.
            }
        }
    }

    override fun onPause() {
        stopPlayback()
        super.onPause()
    }

    override fun onDestroy() {
        stopPlayback()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai.vaachak/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "appVersion" -> result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                "capabilities" -> {
                    val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val memory = ActivityManager.MemoryInfo()
                    manager.getMemoryInfo(memory)
                    val storage = StatFs(filesDir.absolutePath)
                    val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                    val thermal = Build.VERSION.SDK_INT >= 29 && power.currentThermalStatus >= PowerManager.THERMAL_STATUS_MODERATE
                    result.success(mapOf("ramBytes" to memory.totalMem, "freeBytes" to storage.availableBytes,
                        "androidSdk" to Build.VERSION.SDK_INT, "arm64" to Build.SUPPORTED_ABIS.contains("arm64-v8a"),
                        "thermalLimited" to (thermal || memory.lowMemory)))
                }
                "stopPcm" -> {
                    stopPlayback()
                    result.success(null)
                }
                "playPcm" -> {
                    val bytes = call.argument<ByteArray>("samples")
                    val rate = call.argument<Int>("sampleRate")
                    if (bytes == null || rate == null || rate !in 8000..48000 ||
                        bytes.isEmpty() || bytes.size % 2 != 0 || bytes.size > rate * 120) {
                        bytes?.fill(0)
                        result.error("invalid_audio", "Invalid PCM buffer", null)
                    } else {
                        stopPlayback()
                        val ticket = playbackGeneration.get()
                        Thread {
                            var track: AudioTrack? = null
                            var failure: String? = null
                            try {
                                val minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
                                check(minimum > 0) { "Unsupported audio format" }
                                val output = AudioTrack.Builder()
                                    .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                                    .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                                    .setBufferSizeInBytes(maxOf(minimum, 4096))
                                    .setTransferMode(AudioTrack.MODE_STREAM).build()
                                track = output
                                synchronized(audioLock) {
                                    check(ticket == playbackGeneration.get()) { "Playback cancelled" }
                                    playingTrack = output
                                    output.play()
                                }
                                val deadline = android.os.SystemClock.elapsedRealtime() + bytes.size.toLong() * 1000 / (rate * 2) + 2000
                                var offset = 0
                                while (offset < bytes.size && ticket == playbackGeneration.get()) {
                                    check(android.os.SystemClock.elapsedRealtime() < deadline) { "Playback timed out" }
                                    val written = output.write(bytes, offset, minOf(4096, bytes.size - offset), AudioTrack.WRITE_NON_BLOCKING)
                                    check(written >= 0) { "Audio write failed" }
                                    offset += written
                                    if (written == 0) Thread.sleep(10)
                                }
                                while (ticket == playbackGeneration.get() && output.playbackHeadPosition < bytes.size / 2) {
                                    check(android.os.SystemClock.elapsedRealtime() < deadline) { "Playback timed out" }
                                    Thread.sleep(20)
                                }
                                if (ticket != playbackGeneration.get()) failure = "playback_cancelled"
                            } catch (_: Exception) {
                                failure = if (ticket == playbackGeneration.get()) "playback_failed" else "playback_cancelled"
                            } finally {
                                synchronized(audioLock) {
                                    if (playingTrack === track) playingTrack = null
                                    track?.release()
                                }
                                bytes.fill(0)
                                val error = failure
                                runOnUiThread {
                                    if (error == null) result.success(null)
                                    else result.error(error, "Offline playback stopped or unavailable", null)
                                }
                            }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
