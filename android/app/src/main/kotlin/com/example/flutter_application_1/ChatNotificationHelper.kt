package com.example.flutter_application_1

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

object ChatNotificationHelper {

    const val CHAT_CHANNEL_ID = "chat_messages_channel_v2"
    const val ACTION_OPEN_CHAT_NOTIFICATION =
        "com.example.flutter_application_1.ACTION_OPEN_CHAT_NOTIFICATION"

    fun showChatNotification(
        context: Context,
        chatId: String,
        messageId: String,
        senderId: String,
        senderName: String,
        body: String
    ) {
        createChatChannel(context)

        val openChatIntent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_OPEN_CHAT_NOTIFICATION
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("chatId", chatId)
            putExtra("messageId", messageId)
            putExtra("senderId", senderId)
            putExtra("senderName", senderName)
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            (chatId + messageId).hashCode(),
            openChatIntent,
            pendingIntentFlags(updateCurrent = true)
        )

        val notification = NotificationCompat.Builder(context, CHAT_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.sym_action_chat)
            .setContentTitle(senderName)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .build()

        NotificationManagerCompat.from(context)
            .notify((chatId + messageId).hashCode(), notification)
    }

    private fun createChatChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val existing = manager.getNotificationChannel(CHAT_CHANNEL_ID)
        if (existing != null) return

        val channel = NotificationChannel(
            CHAT_CHANNEL_ID,
            "Chat Messages",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Online chat message alerts"
        }

        manager.createNotificationChannel(channel)
    }

    private fun pendingIntentFlags(updateCurrent: Boolean): Int {
        var flags = 0
        if (updateCurrent) {
            flags = flags or PendingIntent.FLAG_UPDATE_CURRENT
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return flags
    }
}
