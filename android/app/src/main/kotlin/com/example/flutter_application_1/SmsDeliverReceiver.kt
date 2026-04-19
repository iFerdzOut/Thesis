package com.example.flutter_application_1

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

class SmsDeliverReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "SmsDeliverReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) {
            return
        }

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isNullOrEmpty()) {
            return
        }

        val pendingResult = goAsync()
        Thread {
            try {
                val groupedBodies = linkedMapOf<String, StringBuilder>()
                val groupedTimestamps = mutableMapOf<String, Long>()
                val simSlot =
                    intent.getIntExtra("slot", intent.getIntExtra("android.telephony.extra.SLOT_INDEX", 0))
                val subscriptionId =
                    intent.getIntExtra("subscription", intent.getIntExtra("subscriptionId", -1))

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
                    processIncomingMessage(
                        context = context,
                        sender = sender,
                        body = body,
                        timestamp = timestamp,
                        simSlot = simSlot,
                        subscriptionId = subscriptionId.takeIf { it >= 0 }
                    )
                }
            } catch (error: Exception) {
                Log.e(TAG, "Failed to process incoming SMS: ${error.message}", error)
            } finally {
                pendingResult.finish()
            }
        }.start()
    }

    private fun processIncomingMessage(
        context: Context,
        sender: String,
        body: String,
        timestamp: Long,
        simSlot: Int,
        subscriptionId: Int?
    ) {
        val messageKey = SmsSyncManager.buildIngressKey(
            address = sender,
            body = body,
            timestamp = timestamp,
            subscriptionId = subscriptionId
        )
        val screeningPayload = mapOf(
            "messageKey" to messageKey,
            "source" to "sms",
            "sender" to sender,
            "peer" to sender,
            "body" to body,
            "timestampMs" to timestamp,
            "simSlot" to simSlot,
            "subscriptionId" to subscriptionId
        )
        val screeningResult =
            toStringKeyMap(SmsFlutterDispatcher.dispatchForResult("screenIncomingSms", screeningPayload))
                ?: fallbackScreeningResult(messageKey)

        val decision = screeningResult["decision"]?.toString() ?: "model_error_fallback"
        val inserted: Map<String, Any?> = if (decision == "quarantine_high_risk") {
            mapOf("providerId" to null, "threadId" to null)
        } else {
            SmsSyncManager.insertIncomingMessage(
                context = context,
                address = sender,
                body = body,
                timestamp = timestamp,
                subscriptionId = subscriptionId
            )
        }

        val senderDisplay = ContactNameResolver.resolveDisplayName(context, sender)
        val payload = mapOf(
            "eventId" to messageKey,
            "messageKey" to messageKey,
            "sender" to sender,
            "senderDisplay" to senderDisplay,
            "body" to body,
            "timestamp" to timestamp,
            "simSlot" to simSlot,
            "subscriptionId" to subscriptionId,
            "providerId" to inserted["providerId"],
            "threadId" to inserted["threadId"],
            "screeningResult" to screeningResult
        )

        val delivered = SmsFlutterDispatcher.dispatch("onIncomingSmsQueued", payload)
        if (!delivered) {
            SmsEventStore.queueEvent(
                context = context,
                eventType = "incomingSms",
                payload = payload
            )
            SmsNotificationHelper.showIncomingNotification(
                context = context,
                sender = sender,
                body = body,
                timestamp = timestamp
            )
        }

        if (inserted["providerId"] != null) {
            SmsFlutterDispatcher.dispatchOrQueue(
                context = context,
                method = "onSmsSyncUpdated",
                eventType = "syncUpdated",
                payload = mapOf(
                    "address" to sender,
                    "providerId" to inserted["providerId"],
                    "threadId" to inserted["threadId"],
                    "reason" to "incoming"
                )
            )
        }

        Log.d(
            TAG,
            "Processed incoming SMS from $sender decision=$decision providerId=${inserted["providerId"]}"
        )
    }

    private fun fallbackScreeningResult(messageKey: String): Map<String, Any?> {
        return mapOf(
            "messageKey" to messageKey,
            "hasUrl" to false,
            "extractedUrls" to emptyList<String>(),
            "primaryUrl" to null,
            "primaryDomain" to null,
            "trustedMatch" to false,
            "mlInvoked" to false,
            "rawLogits" to emptyList<Double>(),
            "riskScore" to 0.0,
            "warningThreshold" to 0.42,
            "quarantineThreshold" to 0.72,
            "decision" to "model_error_fallback",
            "reason" to "Flutter screening was unavailable, so the message was allowed and queued for rescan.",
            "explanations" to listOf(
                "Flutter screening was unavailable, so the message was allowed and queued for rescan."
            ),
            "needsRescan" to true,
            "heuristicScore" to 0.0,
            "modelScore" to null,
            "riskLevel" to "safe",
            "detectionSource" to "native_fail_safe",
            "pipelineStage" to "buffer"
        )
    }

    private fun toStringKeyMap(value: Any?): Map<String, Any?>? {
        val map = value as? Map<*, *> ?: return null
        val normalized = mutableMapOf<String, Any?>()
        for ((key, item) in map) {
            if (key != null) {
                normalized[key.toString()] = item
            }
        }
        return normalized
    }
}
