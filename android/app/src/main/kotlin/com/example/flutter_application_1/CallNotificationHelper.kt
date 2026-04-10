package com.example.flutter_application_1

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person

object CallNotificationHelper {

    const val INCOMING_CALL_CHANNEL_ID = "incoming_call_channel_v5"
    private const val INCOMING_CALL_CHANNEL_NAME = "Incoming Calls"
    private const val TAG = "CallNotificationHelper"

    private val LEGACY_CHANNEL_IDS = listOf(
        "incoming_call_channel",
        "incoming_call_channel_v2",
        "incoming_call_channel_v3",
        "incoming_call_channel_v4"
    )

    fun showIncomingCallNotification(
        context: Context,
        callId: String,
        callerName: String,
        isVideo: Boolean
    ) {
        createIncomingCallChannel(context)

        val notificationId = callId.hashCode()
        val callTypeText = if (isVideo) "Incoming video call" else "Incoming voice call"
        val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val incomingVibrationPattern = longArrayOf(0L, 700L, 500L, 700L)

        val openIntent = Intent(context, IncomingCallActivity::class.java).apply {
            action = IncomingCallActivity.ACTION_OPEN_FROM_NOTIFICATION
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(IncomingCallActivity.EXTRA_CALL_ID, callId)
            putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, callerName)
            putExtra(IncomingCallActivity.EXTRA_IS_VIDEO, isVideo)
            putExtra(IncomingCallActivity.EXTRA_FROM_NOTIFICATION, true)
        }

        val fullScreenPendingIntent = PendingIntent.getActivity(
            context,
            notificationId,
            openIntent,
            pendingIntentFlags(updateCurrent = true)
        )

        val notificationTapIntent = Intent(context, MainActivity::class.java).apply {
            action = IncomingCallActivity.ACTION_OPEN_FROM_NOTIFICATION
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(IncomingCallActivity.EXTRA_CALL_ID, callId)
            putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, callerName)
            putExtra(IncomingCallActivity.EXTRA_IS_VIDEO, isVideo)
        }

        val notificationTapPendingIntent = PendingIntent.getActivity(
            context,
            notificationId + 10,
            notificationTapIntent,
            pendingIntentFlags(updateCurrent = true)
        )

        val acceptIntent = Intent(context, MainActivity::class.java).apply {
            action = CallActionReceiver.ACTION_ACCEPT_CALL
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(IncomingCallActivity.EXTRA_CALL_ID, callId)
            putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, callerName)
            putExtra(IncomingCallActivity.EXTRA_IS_VIDEO, isVideo)
        }

        val declineIntent = Intent(context, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_DECLINE_CALL
            putExtra(IncomingCallActivity.EXTRA_CALL_ID, callId)
            putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, callerName)
            putExtra(IncomingCallActivity.EXTRA_IS_VIDEO, isVideo)
        }

        val acceptPendingIntent = PendingIntent.getActivity(
            context,
            notificationId + 1,
            acceptIntent,
            pendingIntentFlags(updateCurrent = true)
        )

        val declinePendingIntent = PendingIntent.getBroadcast(
            context,
            notificationId + 2,
            declineIntent,
            pendingIntentFlags(updateCurrent = true)
        )

        val callerPerson = Person.Builder()
            .setName(callerName)
            .setImportant(true)
            .build()

        val publicNotification = NotificationCompat.Builder(context, INCOMING_CALL_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle(callerName)
            .setContentText(callTypeText)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Decline",
                declinePendingIntent
            )
            .addAction(
                android.R.drawable.ic_menu_call,
                "Answer",
                acceptPendingIntent
            )
            .build()

        val notification = NotificationCompat.Builder(context, INCOMING_CALL_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle(callerName)
            .setContentText(callTypeText)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPublicVersion(publicNotification)
            .setOngoing(true)
            .setAutoCancel(false)
            .setSilent(false)
            .setOnlyAlertOnce(false)
            .setColor(0xFF075E54.toInt())
            .setColorized(true)
            .setSound(ringtoneUri)
            .setVibrate(incomingVibrationPattern)
            .setContentIntent(notificationTapPendingIntent)
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .setStyle(
                NotificationCompat.CallStyle.forIncomingCall(
                    callerPerson,
                    declinePendingIntent,
                    acceptPendingIntent
                )
            )
            .setTimeoutAfter(30_000L)
            .build()

        try {
            NotificationManagerCompat.from(context).notify(notificationId, notification)
            Log.d(TAG, "Incoming call notification shown for callId=$callId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show incoming call notification: ${e.message}", e)
        }
    }

    fun cancelIncomingCallNotification(context: Context, callId: String) {
        val notificationId = callId.hashCode()
        Log.d(TAG, "Cancel notification for callId=$callId notificationId=$notificationId")
        NotificationManagerCompat.from(context).cancel(notificationId)
    }

    private fun createIncomingCallChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val channelVibrationPattern = longArrayOf(0L, 700L, 500L, 700L)

        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        LEGACY_CHANNEL_IDS.forEach { legacyId ->
            manager.getNotificationChannel(legacyId)?.let {
                manager.deleteNotificationChannel(legacyId)
                Log.d(TAG, "Deleted legacy incoming call channel: $legacyId")
            }
        }

        val existing = manager.getNotificationChannel(INCOMING_CALL_CHANNEL_ID)
        if (existing == null) {
            val channel = NotificationChannel(
                INCOMING_CALL_CHANNEL_ID,
                INCOMING_CALL_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Incoming call alerts"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableVibration(true)
                enableLights(true)
                setBypassDnd(true)
                this.vibrationPattern = channelVibrationPattern
                setSound(ringtoneUri, attributes)
            }

            manager.createNotificationChannel(channel)
            Log.d(TAG, "Created incoming call channel v5")
        } else {
            Log.d(
                TAG,
                "Existing channel found importance=${existing.importance} sound=${existing.sound}"
            )
        }
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
