package com.example.flutter_application_1

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject

class SmsHandlerService : Service() {

    companion object {
        private const val TAG = "SmsHandlerService"
        const val EXTRA_SENDER   = "extra_sender"
        const val EXTRA_BODY     = "extra_body"
        const val EXTRA_SIM_SLOT = "extra_sim_slot"
        const val EXTRA_TIMESTAMP = "extra_timestamp"
        private const val CHANNEL_ID   = "sms_handler_channel"
        private const val NOTIFICATION_ID = 1001
        const val SMS_CHANNEL = "sms_channel"
        private const val SMS_KILLED_APP_CHANNEL_ID = "sms_killed_app_channel"
        private const val PREFS_NAME = "sms_pending_prefs"
        private const val PREF_PENDING_SMS = "pending_sms_messages"
        private const val ACTION_OPEN_SMS_NOTIFICATION =
            "com.example.flutter_application_1.ACTION_OPEN_SMS_NOTIFICATION"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        Log.d(TAG, "SmsHandlerService created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // MANDATORY: Call startForeground immediately to satisfy Android OS timing
        startServiceInForeground()

        if (intent != null) {
            val sender  = intent.getStringExtra(EXTRA_SENDER)  ?: "Unknown"
            val body    = intent.getStringExtra(EXTRA_BODY)    ?: ""
            val simSlot = intent.getIntExtra(EXTRA_SIM_SLOT, 0)
            val timestamp = intent.getLongExtra(EXTRA_TIMESTAMP, System.currentTimeMillis())

            if (body.isNotEmpty()) {
                Log.d(TAG, "Processing SMS from $sender")
                val deliveredToFlutter = forwardToFlutter(sender, body, simSlot, timestamp)
                if (!deliveredToFlutter) {
                    showKilledAppSmsNotification(sender, body, timestamp)
                }
            }
        }

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf(startId)

        return START_NOT_STICKY
    }

    private fun startServiceInForeground() {
        val notification = buildForegroundNotification()
        
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // For Android 14+, we must specify the type if it's in the manifest
                // Type: REMOTE_MESSAGING (matches your manifest)
                startForeground(
                    NOTIFICATION_ID, 
                    notification, 
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
                    } else {
                        0
                    }
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground: ${e.message}")
            // Fallback for older versions
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun forwardToFlutter(sender: String, body: String, simSlot: Int, timestamp: Long): Boolean {
        try {
            val engine: FlutterEngine? = FlutterEngineCache.getInstance().get("main_engine")
            if (engine != null) {
                val channel = MethodChannel(engine.dartExecutor.binaryMessenger, SMS_CHANNEL)
                channel.invokeMethod(
                    "onSmsReceived",
                    mapOf(
                        "sender" to sender,
                        "body" to body,
                        "simSlot" to simSlot,
                        "timestamp" to timestamp
                    )
                )
                Log.d(TAG, "Forwarded SMS to Flutter successfully")
                return true
            } else {
                Log.d(TAG, "Flutter engine not ready; SMS remains in pending queue")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to forward SMS to Flutter: ${e.message}")
        }
        return false
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "SMS Handler Service",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Smishing Shield Background Protection"
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
            if (manager.getNotificationChannel(SMS_KILLED_APP_CHANNEL_ID) == null) {
                val smsChannel = NotificationChannel(
                    SMS_KILLED_APP_CHANNEL_ID,
                    "SMS Messages",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Incoming SMS while the app is closed"
                }
                manager.createNotificationChannel(smsChannel)
            }
        }
    }

    private fun showKilledAppSmsNotification(sender: String, body: String, timestamp: Long) {
        try {
            val notificationKey = "$sender|$timestamp|${body.hashCode()}"
            val openIntent = Intent(this, MainActivity::class.java).apply {
                action = ACTION_OPEN_SMS_NOTIFICATION
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("sender", sender)
                putExtra("body", body)
                putExtra("timestamp", timestamp)
                putExtra("notificationKey", notificationKey)
            }
            val pendingIntent = PendingIntent.getActivity(
                this,
                notificationKey.hashCode(),
                openIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val notification = NotificationCompat.Builder(this, SMS_KILLED_APP_CHANNEL_ID)
                .setContentTitle(sender)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setSmallIcon(android.R.drawable.ic_dialog_email)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()

            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(notificationKey.hashCode(), notification)
            Log.d(TAG, "Displayed killed-app SMS notification for $sender")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show killed-app SMS notification: ${e.message}", e)
        }
    }

    private fun buildForegroundNotification(): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Smishing Shield PH")
            .setContentText("Protecting your messages in the background")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}
