package com.awaaz.sos

import android.media.AudioAttributes
import android.media.MediaPlayer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var sirenPlayer: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.awaaz.sos/siren")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            stopSiren()
                            val descriptor = assets.openFd("flutter_assets/assets/siren.wav")
                            sirenPlayer = MediaPlayer().apply {
                                setAudioAttributes(
                                    AudioAttributes.Builder()
                                        .setUsage(AudioAttributes.USAGE_ALARM)
                                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                        .build()
                                )
                                setDataSource(descriptor.fileDescriptor, descriptor.startOffset, descriptor.length)
                                descriptor.close()
                                isLooping = true
                                prepare()
                                start()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SIREN_ERROR", e.message, null)
                        }
                    }
                    "stop" -> {
                        stopSiren()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun stopSiren() {
        sirenPlayer?.let {
            if (it.isPlaying) it.stop()
            it.release()
        }
        sirenPlayer = null
    }

    override fun onDestroy() {
        stopSiren()
        super.onDestroy()
    }
}
