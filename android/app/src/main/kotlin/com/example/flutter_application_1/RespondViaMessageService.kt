package com.example.flutter_application_1

import android.app.Service
import android.content.Intent
import android.net.Uri
import android.os.IBinder
import android.util.Log

class RespondViaMessageService : Service() {
    companion object {
        private const val TAG = "RespondViaMessageSvc"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val target = extractPhone(intent)
            val body =
                intent?.getStringExtra("sms_body")
                    ?: intent?.getStringExtra(Intent.EXTRA_TEXT)
                    ?: ""
            if (target.isNotBlank() && body.isNotBlank()) {
                SmsPlatformSender.sendTextMessage(
                    context = applicationContext,
                    address = target,
                    body = body,
                    simSlot = 0
                )
            }
        } catch (error: Exception) {
            Log.e(TAG, "Failed quick response SMS: ${error.message}", error)
        } finally {
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun extractPhone(intent: Intent?): String {
        if (intent == null) return ""
        intent.getStringExtra("address")?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        return Uri.decode(intent.dataString ?: "").substringAfter(':', "")
    }
}
