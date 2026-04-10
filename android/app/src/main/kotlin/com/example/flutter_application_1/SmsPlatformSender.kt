package com.example.flutter_application_1

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Log
import java.util.UUID

object SmsPlatformSender {
    private const val TAG = "SmsPlatformSender"

    fun sendTextMessage(
        context: Context,
        address: String,
        body: String,
        simSlot: Int
    ): Map<String, Any?> {
        val provisionalId = UUID.randomUUID().toString()
        val subscriptionId = resolveSubscriptionId(context, simSlot)
        val inserted = SmsSyncManager.insertOutgoingPendingMessage(
            context = context,
            address = address,
            body = body,
            timestamp = System.currentTimeMillis(),
            subscriptionId = subscriptionId
        )

        val providerId = (inserted["providerId"] as? Number)?.toLong()
        val threadId = (inserted["threadId"] as? Number)?.toLong()
        val smsManager = createSmsManager(context, subscriptionId)

        val sentIntent = buildStatusIntent(
            context = context,
            action = SmsIntentActions.ACTION_SMS_SENT,
            requestCodeSeed = providerId?.toInt() ?: provisionalId.hashCode(),
            providerId = providerId,
            address = address,
            provisionalId = provisionalId
        )

        val deliveredIntent = buildStatusIntent(
            context = context,
            action = SmsIntentActions.ACTION_SMS_DELIVERED,
            requestCodeSeed = (providerId?.toInt() ?: provisionalId.hashCode()) + 17,
            providerId = providerId,
            address = address,
            provisionalId = provisionalId
        )

        try {
            val parts = smsManager.divideMessage(body)
            if (parts.size > 1) {
                val sentIntents = ArrayList<PendingIntent>(parts.size).apply {
                    repeat(parts.size) { add(sentIntent) }
                }
                val deliveredIntents = ArrayList<PendingIntent>(parts.size).apply {
                    repeat(parts.size) { add(deliveredIntent) }
                }
                smsManager.sendMultipartTextMessage(
                    address,
                    null,
                    ArrayList(parts),
                    sentIntents,
                    deliveredIntents
                )
            } else {
                smsManager.sendTextMessage(address, null, body, sentIntent, deliveredIntent)
            }
        } catch (error: Exception) {
            Log.e(TAG, "Failed to send SMS: ${error.message}", error)
            if (providerId != null) {
                SmsSyncManager.updateOutgoingStatus(
                    context = context,
                    providerId = providerId,
                    status = "failed"
                )
            }
            throw error
        }

        return mapOf(
            "provisionalId" to provisionalId,
            "providerId" to providerId,
            "threadId" to threadId,
            "subscriptionId" to subscriptionId
        )
    }

    private fun buildStatusIntent(
        context: Context,
        action: String,
        requestCodeSeed: Int,
        providerId: Long?,
        address: String,
        provisionalId: String
    ): PendingIntent {
        val intent = Intent(context, SmsSendStatusReceiver::class.java).apply {
            this.action = action
            putExtra(SmsIntentActions.EXTRA_PROVIDER_ID, providerId)
            putExtra(SmsIntentActions.EXTRA_ADDRESS, address)
            putExtra(SmsIntentActions.EXTRA_PROVISIONAL_ID, provisionalId)
        }

        return PendingIntent.getBroadcast(
            context,
            requestCodeSeed,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun createSmsManager(context: Context, subscriptionId: Int?): SmsManager {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val smsManager = context.getSystemService(SmsManager::class.java)
            return if (subscriptionId != null && subscriptionId >= 0) {
                smsManager.createForSubscriptionId(subscriptionId)
            } else {
                smsManager
            }
        }

        @Suppress("DEPRECATION")
        return if (subscriptionId != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
        } else {
            SmsManager.getDefault()
        }
    }

    private fun resolveSubscriptionId(context: Context, simSlot: Int): Int? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                val manager = context.getSystemService(SubscriptionManager::class.java)
                val active = manager?.activeSubscriptionInfoList ?: emptyList()
                active.firstOrNull { it.simSlotIndex == simSlot }?.subscriptionId
            } else {
                null
            }
        } catch (error: Exception) {
            Log.w(TAG, "Unable to resolve subscription for slot $simSlot: ${error.message}")
            null
        }
    }
}
