package com.example.flutter_application_1

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class SmsSendStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val providerId =
            intent.getLongExtra(SmsIntentActions.EXTRA_PROVIDER_ID, -1L).takeIf { it > 0 }
        val address = intent.getStringExtra(SmsIntentActions.EXTRA_ADDRESS).orEmpty()
        val provisionalId =
            intent.getStringExtra(SmsIntentActions.EXTRA_PROVISIONAL_ID).orEmpty()

        val status = when (intent.action) {
            SmsIntentActions.ACTION_SMS_DELIVERED -> {
                if (resultCode == Activity.RESULT_OK) "delivered" else "sent"
            }
            SmsIntentActions.ACTION_SMS_SENT -> {
                if (resultCode == Activity.RESULT_OK) "sent" else "failed"
            }
            else -> "failed"
        }

        if (providerId != null) {
            SmsSyncManager.updateOutgoingStatus(
                context = context,
                providerId = providerId,
                status = status
            )
        }

        val payload = mapOf(
            "eventId" to "$provisionalId|$status",
            "providerId" to providerId,
            "address" to address,
            "status" to status,
            "provisionalId" to provisionalId
        )

        SmsFlutterDispatcher.dispatchOrQueue(
            context = context,
            method = "onSmsSendStatus",
            eventType = "sendStatus",
            payload = payload
        )
        SmsFlutterDispatcher.dispatchOrQueue(
            context = context,
            method = "onSmsSyncUpdated",
            eventType = "syncUpdated",
            payload = mapOf(
                "address" to address,
                "providerId" to providerId,
                "reason" to "send_status"
            )
        )
    }
}
