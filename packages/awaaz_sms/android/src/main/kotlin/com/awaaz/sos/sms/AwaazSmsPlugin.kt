package com.awaaz.sos.sms

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AwaazSmsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.awaaz.sos/sms")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "send") {
            result.notImplemented()
            return
        }

        if (context.checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            result.error("SMS_PERMISSION_DENIED", "SMS permission is not granted.", null)
            return
        }

        val phoneNumber = call.argument<String>("phoneNumber")
        val message = call.argument<String>("message")
        if (phoneNumber.isNullOrBlank() || message.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "A phone number and message are required.", null)
            return
        }

        try {
            val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }
            val parts = smsManager.divideMessage(message)
            if (parts.size == 1) {
                smsManager.sendTextMessage(phoneNumber, null, message, null, null)
            } else {
                smsManager.sendMultipartTextMessage(phoneNumber, null, parts, null, null)
            }
            result.success(null)
        } catch (error: SecurityException) {
            result.error("SMS_PERMISSION_DENIED", error.message, null)
        } catch (error: Exception) {
            result.error("SMS_SEND_FAILED", error.message, null)
        }
    }
}
