package com.example.flutter_application_1

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

class SmsReceivedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) {
            return
        }

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isNullOrEmpty()) {
            return
        }

        val groupedBodies = linkedMapOf<String, StringBuilder>()
        val groupedTimestamps = mutableMapOf<String, Long>()
        val simSlot =
            intent.getIntExtra("slot", intent.getIntExtra("android.telephony.extra.SLOT_INDEX", 0))

        for (sms in messages) {
            val sender = sms.originatingAddress ?: "Unknown"
            groupedBodies.getOrPut(sender) { StringBuilder() }.append(sms.messageBody.orEmpty())
            val timestamp = sms.timestampMillis
            val currentTimestamp = groupedTimestamps[sender] ?: 0L
            if (timestamp > currentTimestamp) {
                groupedTimestamps[sender] = timestamp
            }
        }

        for ((sender, bodyBuilder) in groupedBodies) {
            val body = bodyBuilder.toString()
            if (body.isBlank()) continue
            val timestamp = groupedTimestamps[sender] ?: System.currentTimeMillis()
            val senderDisplay = ContactNameResolver.resolveDisplayName(context, sender)
            val payload = mapOf(
                "eventId" to SmsSyncManager.buildIngressKey(sender, body, timestamp, null),
                "sender" to sender,
                "senderDisplay" to senderDisplay,
                "body" to body,
                "timestamp" to timestamp,
                "simSlot" to simSlot,
                "providerId" to null,
                "threadId" to null,
                "limitedMode" to true
            )

            SmsFlutterDispatcher.dispatchOrQueue(
                context = context,
                method = "onIncomingSmsQueued",
                eventType = "incomingSms",
                payload = payload
            )
            SmsFlutterDispatcher.dispatchOrQueue(
                context = context,
                method = "onSmsSyncUpdated",
                eventType = "syncUpdated",
                payload = mapOf(
                    "address" to sender,
                    "threadId" to null,
                    "reason" to "incoming_limited"
                )
            )
        }
    }
}
