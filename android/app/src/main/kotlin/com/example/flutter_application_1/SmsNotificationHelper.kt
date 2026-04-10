package com.example.flutter_application_1

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

object SmsNotificationHelper {
    private const val SAFE_CHANNEL_ID = "sms_safe_channel"
    private const val SUSPICIOUS_CHANNEL_ID = "sms_suspicious_channel"

    fun showIncomingNotification(
        context: Context,
        sender: String,
        body: String,
        timestamp: Long,
        isSuspicious: Boolean = false
    ) {
        val notificationKey = "$sender|$timestamp|${body.hashCode()}"
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (manager.getNotificationChannel(SAFE_CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        SAFE_CHANNEL_ID,
                        "SMS Messages",
                        NotificationManager.IMPORTANCE_HIGH
                    )
                )
            }
            if (manager.getNotificationChannel(SUSPICIOUS_CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        SUSPICIOUS_CHANNEL_ID,
                        "Suspicious Messages",
                        NotificationManager.IMPORTANCE_HIGH
                    )
                )
            }
        }

        val openIntent = Intent(context, MainActivity::class.java).apply {
            action = SmsIntentActions.ACTION_OPEN_SMS_NOTIFICATION
            flags =
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(SmsIntentActions.EXTRA_SENDER, sender)
            putExtra(SmsIntentActions.EXTRA_BODY, body)
            putExtra(SmsIntentActions.EXTRA_TIMESTAMP, timestamp)
            putExtra(SmsIntentActions.EXTRA_NOTIFICATION_KEY, notificationKey)
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            notificationKey.hashCode(),
            openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val senderDisplay = ContactNameResolver.resolveDisplayName(context, sender)
        val contentText = if (isSuspicious) {
            "A suspicious message was blocked and moved to Quarantine Vault."
        } else {
            body
        }

        val notification = NotificationCompat.Builder(
            context,
            if (isSuspicious) SUSPICIOUS_CHANNEL_ID else SAFE_CHANNEL_ID
        )
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(
                if (isSuspicious) {
                    "Suspicious message from $senderDisplay"
                } else {
                    senderDisplay
                }
            )
            .setContentText(contentText)
            .setStyle(NotificationCompat.BigTextStyle().bigText(contentText))
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        manager.notify(notificationKey.hashCode(), notification)
    }
}
