package com.example.flutter_application_1

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

class SmsReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "SmsReceiver"
        private const val PREFS_NAME = "sms_pending_prefs"
        private const val PREF_PENDING_SMS = "pending_sms_messages"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "onReceive: action=${intent.action}")

        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION &&
            intent.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION
        ) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isNullOrEmpty()) return

        val grouped = mutableMapOf<String, StringBuilder>()
        val senderTimestamps = mutableMapOf<String, Long>()
        var simSlot = intent.getIntExtra("slot", -1)
        if (simSlot == -1) simSlot = intent.getIntExtra("android.telephony.extra.SLOT_INDEX", 0)

        for (sms in messages) {
            val sender = sms.originatingAddress ?: "Unknown"
            grouped.getOrPut(sender) { StringBuilder() }.append(sms.messageBody)
            val timestamp = sms.timestampMillis
            val existing = senderTimestamps[sender] ?: 0L
            if (timestamp > existing) {
                senderTimestamps[sender] = timestamp
            }
        }

        for ((sender, body) in grouped) {
            Log.d(TAG, "SMS from $sender")
            val timestamp = senderTimestamps[sender] ?: System.currentTimeMillis()
            persistPendingSms(
                context = context,
                sender = sender,
                body = body.toString(),
                simSlot = simSlot,
                timestamp = timestamp
            )
            val serviceIntent = Intent(context, SmsHandlerService::class.java).apply {
                putExtra(SmsHandlerService.EXTRA_SENDER, sender)
                putExtra(SmsHandlerService.EXTRA_BODY, body.toString())
                putExtra(SmsHandlerService.EXTRA_SIM_SLOT, simSlot)
                putExtra(SmsHandlerService.EXTRA_TIMESTAMP, timestamp)
            }
            context.startForegroundService(serviceIntent)
        }
    }

    private fun persistPendingSms(
        context: Context,
        sender: String,
        body: String,
        simSlot: Int,
        timestamp: Long
    ) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(PREF_PENDING_SMS, "[]") ?: "[]"
            val array = JSONArray(raw)
            val newKey = buildMessageKey(sender, body, timestamp)

            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                val existingKey = buildMessageKey(
                    item.optString("sender"),
                    item.optString("body"),
                    item.optLong("timestamp", 0L)
                )
                if (existingKey == newKey) {
                    return
                }
            }

            val item = JSONObject()
                .put("sender", sender)
                .put("body", body)
                .put("simSlot", simSlot)
                .put("timestamp", timestamp)
            array.put(item)
            prefs.edit().putString(PREF_PENDING_SMS, array.toString()).apply()
            Log.d(TAG, "Queued pending SMS for $sender")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to queue pending SMS: ${e.message}", e)
        }
    }

    private fun buildMessageKey(sender: String, body: String, timestamp: Long): String {
        return "$sender|$timestamp|${body.hashCode()}"
    }
}
