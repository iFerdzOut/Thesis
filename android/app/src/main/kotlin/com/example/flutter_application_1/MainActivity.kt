package com.example.flutter_application_1

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.role.RoleManager
import android.content.Intent
import android.content.res.Configuration
import android.media.AudioManager
import android.media.AudioFocusRequest
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.os.Build
import android.util.Rational
import android.provider.Telephony
import android.provider.ContactsContract
import android.provider.Settings
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Log
import androidx.annotation.NonNull
import androidx.core.app.NotificationCompat
import com.google.firebase.firestore.FirebaseFirestore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val SMS_CHANNEL = "sms_channel"
        private const val CHAT_NOTIFICATION_CHANNEL = "chat_notification_channel"
        private const val FRIEND_REQUEST_NOTIFICATION_CHANNEL = "friend_request_notification_channel"
        private const val REQUEST_CODE_DEFAULT_SMS = 1001
        private const val PREFS_NAME = "incoming_call_prefs"
        private const val PREF_PENDING_ARGS = "pending_call_args"
        private const val PREF_PENDING_KEY = "pending_call_key"
        private const val PREF_PENDING_CHAT_ARGS = "pending_chat_args"
        private const val PREF_PENDING_CHAT_KEY = "pending_chat_key"
        private const val PREF_PENDING_SMS_NOTIFICATION_ARGS = "pending_sms_notification_args"
        private const val PREF_PENDING_SMS_NOTIFICATION_KEY = "pending_sms_notification_key"
        private const val PREF_PENDING_FRIEND_REQUEST_ARGS = "pending_friend_request_args"
        private const val PREF_PENDING_FRIEND_REQUEST_KEY = "pending_friend_request_key"
        private const val PREF_MUTED_CHAT_SENDERS = "muted_chat_senders"
        private const val PREF_BLOCKED_CHAT_SENDERS = "blocked_chat_senders"
        private val DEFAULT_PIP_RATIO = Rational(9, 16)
        private var ringtonePlayer: MediaPlayer? = null
        private var outgoingToneGenerator: ToneGenerator? = null
        private var outgoingToneHandler: Handler? = null
        private val handledIntentKeys = mutableSetOf<String>()
        private var pendingCallIntentArgs: Map<String, Any>? = null
        private var pendingCallIntentKey: String? = null
        private val handledChatIntentKeys = mutableSetOf<String>()
        private var pendingChatIntentArgs: Map<String, Any>? = null
        private var pendingChatIntentKey: String? = null
        private val handledSmsIntentKeys = mutableSetOf<String>()
        private var pendingSmsIntentArgs: Map<String, Any>? = null
        private var pendingSmsIntentKey: String? = null
        private val handledFriendRequestIntentKeys = mutableSetOf<String>()
        private var pendingFriendRequestIntentArgs: Map<String, Any>? = null
        private var pendingFriendRequestIntentKey: String? = null
        private var videoCallPictureInPictureEnabled: Boolean = false
        private const val ACTION_OPEN_SMS_NOTIFICATION =
            "com.example.flutter_application_1.ACTION_OPEN_SMS_NOTIFICATION"
        private const val ACTION_OPEN_FRIEND_REQUEST_NOTIFICATION =
            "com.example.flutter_application_1.ACTION_OPEN_FRIEND_REQUEST_NOTIFICATION"
    }

    private lateinit var channel: MethodChannel
    private lateinit var chatChannel: MethodChannel
    private lateinit var friendRequestChannel: MethodChannel
    private lateinit var smsBridge: NativeSmsBridge
    private var callAudioFocusRequest: AudioFocusRequest? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put("main_engine", flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL)
        chatChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHAT_NOTIFICATION_CHANNEL)
        friendRequestChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FRIEND_REQUEST_NOTIFICATION_CHANNEL)
        smsBridge = NativeSmsBridge(this, channel)

        channel.setMethodCallHandler { call, result ->
            if (smsBridge.handleMethodCall(call, result)) {
                return@setMethodCallHandler
            }
            when (call.method) {
                "isDefaultSmsApp" -> result.success(isDefaultSmsApp())

                "requestDefaultSmsApp" -> {
                    requestDefaultSmsApp()
                    result.success(null)
                }

                "openDefaultSmsSettings" -> {
                    openDefaultSmsSettings()
                    result.success(null)
                }

                "openDialer" -> {
                    val phone = call.argument<String>("phone") ?: ""
                    openDialer(phone)
                    result.success(null)
                }

                "openAddContact" -> {
                    val phone = call.argument<String>("phone") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    openAddContact(phone, name)
                    result.success(null)
                }

                "sendSMS" -> {
                    val phone = call.argument<String>("phone")
                    val message = call.argument<String>("message")
                    val simSlot = call.argument<Int>("simSlot") ?: 0

                    if (phone != null && message != null) {
                        try {
                            sendSmsNative(phone, message, simSlot)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SMS_SEND_FAILED", e.message, null)
                        }
                    } else {
                        result.error("INVALID_PARAMS", "Phone or message null", null)
                    }
                }

                "getSimSlots" -> {
                    result.success(getSimSlots())
                }

                "showNotification" -> {
                    val sender = call.argument<String>("sender") ?: "Unknown"
                    val body = call.argument<String>("body") ?: ""
                    val isSuspicious = call.argument<Boolean>("isSuspicious") ?: false
                    val timestamp = call.argument<Number>("timestamp")?.toLong()
                        ?: System.currentTimeMillis()
                    showSmsNotification(sender, body, isSuspicious, timestamp)
                    result.success(null)
                }

                "showChatNotification" -> {
                    val chatId = call.argument<String>("chatId") ?: ""
                    val messageId = call.argument<String>("messageId") ?: ""
                    val senderId = call.argument<String>("senderId") ?: ""
                    val sender = call.argument<String>("sender") ?: "New message"
                    val body = call.argument<String>("body") ?: ""
                    showChatNotification(
                        chatId = chatId,
                        messageId = messageId,
                        senderId = senderId,
                        sender = sender,
                        body = body
                    )
                    result.success(null)
                }

                "showFriendRequestNotification" -> {
                    val senderId = call.argument<String>("senderId") ?: ""
                    val sender = call.argument<String>("sender") ?: "New friend request"
                    showFriendRequestNotification(senderId, sender)
                    result.success(null)
                }

                "startRingtone" -> {
                    startRingtone()
                    result.success(null)
                }

                "stopRingtone" -> {
                    stopRingtone()
                    result.success(null)
                }

                "startOutgoingRingtone" -> {
                    startOutgoingRingtone()
                    result.success(null)
                }

                "stopOutgoingRingtone" -> {
                    stopOutgoingRingtone()
                    result.success(null)
                }

                "prepareIncomingRingtoneAudio" -> {
                    prepareIncomingRingtoneAudio()
                    result.success(null)
                }

                "prepareCallAudioState" -> {
                    val speaker = call.argument<Boolean>("speaker") ?: false
                    prepareCallAudioState(speaker)
                    result.success(null)
                }

                "setSpeakerphoneOn" -> {
                    val speaker = call.argument<Boolean>("speaker") ?: false
                    setSpeakerphoneOn(speaker)
                    result.success(null)
                }

                "resetCallAudioState" -> {
                    resetCallAudioState()
                    result.success(null)
                }

                "supportsPictureInPicture" -> {
                    result.success(supportsPictureInPicture())
                }

                "enterPictureInPicture" -> {
                    result.success(enterPictureInPicture())
                }

                "isInPictureInPictureMode" -> {
                    result.success(isCurrentlyInPictureInPictureMode())
                }

                "setVideoCallPictureInPictureEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    setVideoCallPictureInPictureEnabled(enabled)
                    result.success(null)
                }

                "consumePendingCallIntent" -> {
                    result.success(pendingCallIntentArgs ?: loadPendingCallIntentArgs())
                }

                "consumePendingSmsMessages" -> {
                    result.success(consumePendingSmsMessages())
                }

                "consumePendingSmsIntent" -> {
                    result.success(pendingSmsIntentArgs ?: loadPendingSmsIntentArgs())
                }

                "getRecentDeviceSms" -> {
                    val sinceTimestamp = call.argument<Number>("sinceTimestamp")?.toLong() ?: 0L
                    val maxCount = call.argument<Number>("maxCount")?.toInt() ?: 250
                    result.success(getRecentDeviceSms(sinceTimestamp, maxCount))
                }

                "markSmsIntentHandled" -> {
                    val notificationKey = call.argument<String>("notificationKey") ?: ""
                    if (notificationKey.isNotBlank()) {
                        handledSmsIntentKeys.add(notificationKey)
                        if (pendingSmsIntentKey == notificationKey) {
                            pendingSmsIntentArgs = null
                            pendingSmsIntentKey = null
                            clearPendingSmsIntent()
                        }
                    }
                    result.success(null)
                }

                "markCallIntentHandled" -> {
                    val action = call.argument<String>("action") ?: ""
                    val callId = call.argument<String>("callId") ?: ""

                    if (action.isNotBlank() && callId.isNotBlank()) {
                        val handledKey = "$callId|$action"
                        handledIntentKeys.add(handledKey)

                        if (pendingCallIntentKey == handledKey) {
                            pendingCallIntentArgs = null
                            pendingCallIntentKey = null
                            clearPendingCallIntent()
                        }
                    }

                    result.success(null)
                }

                "canUseFullScreenIntent" -> {
                    result.success(canUseFullScreenIntent())
                }

                "openFullScreenIntentSettings" -> {
                    openFullScreenIntentSettings()
                    result.success(null)
                }

                "openIncomingCallChannelSettings" -> {
                    openIncomingCallChannelSettings()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        chatChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumePendingChatIntent" -> {
                    result.success(pendingChatIntentArgs ?: loadPendingChatIntentArgs())
                }
                "markChatIntentHandled" -> {
                    val chatId = call.argument<String>("chatId") ?: ""
                    val messageId = call.argument<String>("messageId") ?: ""
                    if (chatId.isNotBlank() && messageId.isNotBlank()) {
                        val handledKey = "$chatId|$messageId"
                        handledChatIntentKeys.add(handledKey)
                        if (pendingChatIntentKey == handledKey) {
                            pendingChatIntentArgs = null
                            pendingChatIntentKey = null
                            clearPendingChatIntent()
                        }
                    }
                    result.success(null)
                }
                "updateChatNotificationPreferences" -> {
                    val mutedSenderIds =
                        (call.argument<List<*>>("mutedSenderIds") ?: emptyList<Any?>())
                            .mapNotNull { it?.toString()?.trim() }
                            .filter { it.isNotEmpty() }
                            .toSet()
                    val blockedSenderIds =
                        (call.argument<List<*>>("blockedSenderIds") ?: emptyList<Any?>())
                            .mapNotNull { it?.toString()?.trim() }
                            .filter { it.isNotEmpty() }
                            .toSet()
                    saveChatNotificationPreferences(mutedSenderIds, blockedSenderIds)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        friendRequestChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumePendingFriendRequestIntent" -> {
                    result.success(
                        pendingFriendRequestIntentArgs ?: loadPendingFriendRequestIntentArgs()
                    )
                }
                "markFriendRequestIntentHandled" -> {
                    val senderId = call.argument<String>("senderId") ?: ""
                    if (senderId.isNotBlank()) {
                        handledFriendRequestIntentKeys.add(senderId)
                        if (pendingFriendRequestIntentKey == senderId) {
                            pendingFriendRequestIntentArgs = null
                            pendingFriendRequestIntentKey = null
                            clearPendingFriendRequestIntent()
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (::smsBridge.isInitialized && smsBridge.handleActivityResult(requestCode, resultCode)) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!videoCallPictureInPictureEnabled || isCurrentlyInPictureInPictureMode()) {
            return
        }
        enterPictureInPictureInternal()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)

        if (::channel.isInitialized) {
            channel.invokeMethod(
                "onPictureInPictureModeChanged",
                mapOf("isInPictureInPicture" to isInPictureInPictureMode)
            )
        }
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null || !::channel.isInitialized) return

        val action = intent.action ?: "NONE"
        if (::smsBridge.isInitialized && smsBridge.handleIntent(intent)) {
            return
        }
        if (action == ChatNotificationHelper.ACTION_OPEN_CHAT_NOTIFICATION) {
            handleChatIntent(intent)
            return
        }
        if (action == ACTION_OPEN_SMS_NOTIFICATION) {
            handleSmsIntent(intent)
            return
        }
        if (action == ACTION_OPEN_FRIEND_REQUEST_NOTIFICATION) {
            handleFriendRequestIntent(intent)
            return
        }

        val callId = intent.getStringExtra(IncomingCallActivity.EXTRA_CALL_ID)

        Log.d(TAG, "handleIntent action=$action callId=$callId")

        if (callId.isNullOrBlank()) return

        val shouldHandle =
            action == CallActionReceiver.ACTION_ACCEPT_CALL ||
                action == IncomingCallActivity.ACTION_OPEN_FROM_NOTIFICATION

        if (!shouldHandle) {
            Log.d(TAG, "Ignoring unrelated intent action=$action")
            return
        }

        val handledKey = "$callId|$action"

        if (handledIntentKeys.contains(handledKey)) {
            Log.d(TAG, "Call intent already handled, ignoring duplicate key=$handledKey")
            return
        }

        CallNotificationHelper.cancelIncomingCallNotification(this, callId)
        stopRingtone()

        val args = mapOf(
            "action" to action,
            "callId" to callId,
            "callerName" to (intent.getStringExtra(IncomingCallActivity.EXTRA_CALLER_NAME) ?: ""),
            "isVideo" to intent.getBooleanExtra(IncomingCallActivity.EXTRA_IS_VIDEO, false)
        )

        pendingCallIntentArgs = args
        pendingCallIntentKey = handledKey
        persistPendingCallIntent(args, handledKey)

        if (action == CallActionReceiver.ACTION_ACCEPT_CALL) {
            FirebaseFirestore.getInstance()
                .collection("calls")
                .document(callId)
                .update("status", "accepted")
                .addOnFailureListener { error ->
                    Log.e(TAG, "Failed to mark accepted from MainActivity: ${error.message}", error)
                }
        }

        channel.invokeMethod("onCallIntentReceived", args)
    }

    private fun handleChatIntent(intent: Intent) {
        if (!::chatChannel.isInitialized) return

        val chatId = intent.getStringExtra("chatId") ?: return
        val messageId = intent.getStringExtra("messageId") ?: return
        val senderId = intent.getStringExtra("senderId") ?: return
        val senderName = intent.getStringExtra("senderName") ?: "New message"
        val handledKey = "$chatId|$messageId"

        if (handledChatIntentKeys.contains(handledKey)) {
            Log.d(TAG, "Chat intent already handled, ignoring duplicate key=$handledKey")
            return
        }

        val args = mapOf(
            "chatId" to chatId,
            "messageId" to messageId,
            "senderId" to senderId,
            "senderName" to senderName
        )

        pendingChatIntentArgs = args
        pendingChatIntentKey = handledKey
        persistPendingChatIntent(args, handledKey)
        chatChannel.invokeMethod("onChatIntentReceived", args)
    }

    private fun handleSmsIntent(intent: Intent) {
        if (!::channel.isInitialized) return

        val sender = intent.getStringExtra("sender") ?: return
        val body = intent.getStringExtra("body") ?: ""
        val timestamp = intent.getLongExtra("timestamp", System.currentTimeMillis())
        val notificationKey = intent.getStringExtra("notificationKey")
            ?: "$sender|$timestamp|${body.hashCode()}"

        if (handledSmsIntentKeys.contains(notificationKey)) {
            Log.d(TAG, "SMS intent already handled, ignoring duplicate key=$notificationKey")
            return
        }

        val args = mapOf(
            "sender" to sender,
            "body" to body,
            "timestamp" to timestamp,
            "notificationKey" to notificationKey,
        )

        pendingSmsIntentArgs = args
        pendingSmsIntentKey = notificationKey
        persistPendingSmsIntent(args, notificationKey)
        channel.invokeMethod("onSmsNotificationIntentReceived", args)
    }

    private fun handleFriendRequestIntent(intent: Intent) {
        if (!::friendRequestChannel.isInitialized) return

        val senderId = intent.getStringExtra("senderId") ?: return
        val senderName = intent.getStringExtra("senderName") ?: "Someone"
        val handledKey = senderId

        if (handledFriendRequestIntentKeys.contains(handledKey)) {
            Log.d(TAG, "Friend request intent already handled, ignoring duplicate key=$handledKey")
            return
        }

        val args = mapOf(
            "senderId" to senderId,
            "senderName" to senderName,
        )

        pendingFriendRequestIntentArgs = args
        pendingFriendRequestIntentKey = handledKey
        persistPendingFriendRequestIntent(args, handledKey)
        friendRequestChannel.invokeMethod("onFriendRequestIntentReceived", args)
    }

    private fun persistPendingCallIntent(args: Map<String, Any>, handledKey: String) {
        try {
            val json = JSONObject()
            args.forEach { (key, value) -> json.put(key, value) }
            getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                .edit()
                .putString(PREF_PENDING_ARGS, json.toString())
                .putString(PREF_PENDING_KEY, handledKey)
                .apply()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to persist pending call intent: ${e.message}", e)
        }
    }

    private fun loadPendingCallIntentArgs(): Map<String, Any>? {
        return try {
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            val rawArgs = prefs.getString(PREF_PENDING_ARGS, null) ?: return null
            val rawKey = prefs.getString(PREF_PENDING_KEY, null)
            val json = JSONObject(rawArgs)

            val args = mutableMapOf<String, Any>()
            args["action"] = json.optString("action")
            args["callId"] = json.optString("callId")
            args["callerName"] = json.optString("callerName")
            args["isVideo"] = json.optBoolean("isVideo", false)

            pendingCallIntentArgs = args
            pendingCallIntentKey = rawKey
            args
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load pending call intent: ${e.message}", e)
            null
        }
    }

    private fun clearPendingCallIntent() {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .remove(PREF_PENDING_ARGS)
            .remove(PREF_PENDING_KEY)
            .apply()
    }

    private fun persistPendingSmsIntent(args: Map<String, Any>, handledKey: String) {
        try {
            val json = JSONObject()
            args.forEach { (key, value) -> json.put(key, value) }
            getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                .edit()
                .putString(PREF_PENDING_SMS_NOTIFICATION_ARGS, json.toString())
                .putString(PREF_PENDING_SMS_NOTIFICATION_KEY, handledKey)
                .apply()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to persist pending SMS intent: ${e.message}", e)
        }
    }

    private fun loadPendingSmsIntentArgs(): Map<String, Any>? {
        return try {
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            val rawArgs = prefs.getString(PREF_PENDING_SMS_NOTIFICATION_ARGS, null) ?: return null
            val rawKey = prefs.getString(PREF_PENDING_SMS_NOTIFICATION_KEY, null)
            val json = JSONObject(rawArgs)

            val args = mutableMapOf<String, Any>()
            args["sender"] = json.optString("sender")
            args["body"] = json.optString("body")
            args["timestamp"] = json.optLong("timestamp", System.currentTimeMillis())
            args["notificationKey"] = rawKey ?: json.optString("notificationKey")

            pendingSmsIntentArgs = args
            pendingSmsIntentKey = rawKey
            args
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load pending SMS intent: ${e.message}", e)
            null
        }
    }

    private fun clearPendingSmsIntent() {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .remove(PREF_PENDING_SMS_NOTIFICATION_ARGS)
            .remove(PREF_PENDING_SMS_NOTIFICATION_KEY)
            .apply()
    }

    private fun persistPendingChatIntent(args: Map<String, Any>, handledKey: String) {
        try {
            val json = JSONObject()
            args.forEach { (key, value) -> json.put(key, value) }
            getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                .edit()
                .putString(PREF_PENDING_CHAT_ARGS, json.toString())
                .putString(PREF_PENDING_CHAT_KEY, handledKey)
                .apply()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to persist pending chat intent: ${e.message}", e)
        }
    }

    private fun loadPendingChatIntentArgs(): Map<String, Any>? {
        return try {
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            val rawArgs = prefs.getString(PREF_PENDING_CHAT_ARGS, null) ?: return null
            val rawKey = prefs.getString(PREF_PENDING_CHAT_KEY, null)
            val json = JSONObject(rawArgs)

            val args = mutableMapOf<String, Any>()
            args["chatId"] = json.optString("chatId")
            args["messageId"] = json.optString("messageId")
            args["senderId"] = json.optString("senderId")
            args["senderName"] = json.optString("senderName")

            pendingChatIntentArgs = args
            pendingChatIntentKey = rawKey
            args
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load pending chat intent: ${e.message}", e)
            null
        }
    }

    private fun clearPendingChatIntent() {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .remove(PREF_PENDING_CHAT_ARGS)
            .remove(PREF_PENDING_CHAT_KEY)
            .apply()
    }

    private fun persistPendingFriendRequestIntent(args: Map<String, Any>, handledKey: String) {
        try {
            val json = JSONObject()
            args.forEach { (key, value) -> json.put(key, value) }
            getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                .edit()
                .putString(PREF_PENDING_FRIEND_REQUEST_ARGS, json.toString())
                .putString(PREF_PENDING_FRIEND_REQUEST_KEY, handledKey)
                .apply()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to persist pending friend request intent: ${e.message}", e)
        }
    }

    private fun loadPendingFriendRequestIntentArgs(): Map<String, Any>? {
        return try {
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            val rawArgs = prefs.getString(PREF_PENDING_FRIEND_REQUEST_ARGS, null) ?: return null
            val rawKey = prefs.getString(PREF_PENDING_FRIEND_REQUEST_KEY, null)
            val json = JSONObject(rawArgs)

            val args = mutableMapOf<String, Any>()
            args["senderId"] = json.optString("senderId")
            args["senderName"] = json.optString("senderName")

            pendingFriendRequestIntentArgs = args
            pendingFriendRequestIntentKey = rawKey
            args
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load pending friend request intent: ${e.message}", e)
            null
        }
    }

    private fun clearPendingFriendRequestIntent() {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .remove(PREF_PENDING_FRIEND_REQUEST_ARGS)
            .remove(PREF_PENDING_FRIEND_REQUEST_KEY)
            .apply()
    }

    private fun consumePendingSmsMessages(): List<Map<String, Any>> {
        return try {
            val prefs = getSharedPreferences("sms_pending_prefs", MODE_PRIVATE)
            val raw = prefs.getString("pending_sms_messages", "[]") ?: "[]"
            val array = JSONArray(raw)
            val items = mutableListOf<Map<String, Any>>()
            val seenKeys = mutableSetOf<String>()

            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                val sender = item.optString("sender")
                val body = item.optString("body")
                val timestamp = item.optLong("timestamp", System.currentTimeMillis())
                val messageKey = "$sender|$timestamp|${body.hashCode()}"
                if (!seenKeys.add(messageKey)) {
                    continue
                }
                    items.add(
                        mapOf(
                            "sender" to sender,
                            "body" to body,
                            "simSlot" to item.optInt("simSlot", 0),
                            "timestamp" to timestamp
                        )
                    )
            }

            prefs.edit().remove("pending_sms_messages").apply()
            items
        } catch (e: Exception) {
            Log.e(TAG, "Failed to consume pending SMS messages: ${e.message}", e)
            emptyList()
        }
    }

    private fun getRecentDeviceSms(sinceTimestamp: Long, maxCount: Int): List<Map<String, Any>> {
        val items = mutableListOf<Map<String, Any>>()
        try {
            val projection = arrayOf(
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE
            )
            val selection = if (sinceTimestamp > 0L) {
                "${Telephony.Sms.DATE} > ?"
            } else {
                null
            }
            val selectionArgs = if (sinceTimestamp > 0L) {
                arrayOf(sinceTimestamp.toString())
            } else {
                null
            }
            val cursor = contentResolver.query(
                Telephony.Sms.Inbox.CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                "${Telephony.Sms.DATE} DESC"
            )

            cursor?.use {
                val addressIndex = it.getColumnIndex(Telephony.Sms.ADDRESS)
                val bodyIndex = it.getColumnIndex(Telephony.Sms.BODY)
                val dateIndex = it.getColumnIndex(Telephony.Sms.DATE)
                var count = 0
                while (it.moveToNext() && (maxCount <= 0 || count < maxCount)) {
                    val sender =
                        if (addressIndex >= 0) it.getString(addressIndex) ?: "Unknown" else "Unknown"
                    val body =
                        if (bodyIndex >= 0) it.getString(bodyIndex) ?: "" else ""
                    val timestamp =
                        if (dateIndex >= 0) it.getLong(dateIndex) else System.currentTimeMillis()

                    if (body.isBlank()) continue

                    items.add(
                        mapOf(
                            "sender" to sender,
                            "body" to body,
                            "simSlot" to 0,
                            "timestamp" to timestamp
                        )
                    )
                    count++
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to query recent device SMS: ${e.message}", e)
        }

        return items
    }

    private fun isDefaultSmsApp(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = getSystemService(RoleManager::class.java)
            roleManager.isRoleHeld(RoleManager.ROLE_SMS)
        } else {
            val defaultSmsPackage = Telephony.Sms.getDefaultSmsPackage(this)
            defaultSmsPackage == packageName
        }
    }

    private fun requestDefaultSmsApp() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = getSystemService(RoleManager::class.java)
            try {
                val roleIntent = roleManager.createRequestRoleIntent(RoleManager.ROLE_SMS)
                startActivityForResult(roleIntent, REQUEST_CODE_DEFAULT_SMS)
            } catch (e: Exception) {
                Log.e(TAG, "requestDefaultSmsApp failed, opening settings: ${e.message}", e)
                openDefaultSmsSettings()
            }
        } else {
            try {
                val changeIntent = Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT).apply {
                    putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, packageName)
                }
                startActivityForResult(changeIntent, REQUEST_CODE_DEFAULT_SMS)
            } catch (e: Exception) {
                Log.e(TAG, "Legacy default SMS request failed, opening settings: ${e.message}", e)
                openDefaultSmsSettings()
            }
        }
    }

    private fun openDefaultSmsSettings() {
        val intent =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
            }

        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun openDialer(phone: String) {
        val sanitized = phone.trim()
        val uri = if (sanitized.isNotEmpty()) {
            Uri.parse("tel:$sanitized")
        } else {
            Uri.parse("tel:")
        }

        val intent = Intent(Intent.ACTION_DIAL, uri).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun openAddContact(phone: String, name: String) {
        val intent = Intent(ContactsContract.Intents.Insert.ACTION).apply {
            type = ContactsContract.RawContacts.CONTENT_TYPE
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (phone.trim().isNotEmpty()) {
                putExtra(ContactsContract.Intents.Insert.PHONE, phone.trim())
            }
            if (name.trim().isNotEmpty() && name.trim() != phone.trim()) {
                putExtra(ContactsContract.Intents.Insert.NAME, name.trim())
            }
        }
        startActivity(intent)
    }

    private fun sendSmsNative(phone: String, message: String, simSlot: Int) {
        val smsManager: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val subscriptionManager = getSystemService(SubscriptionManager::class.java)
            val subscriptionList = subscriptionManager.activeSubscriptionInfoList ?: emptyList()
            val subscriptionInfo = subscriptionList.find { info -> info.simSlotIndex == simSlot }

            if (subscriptionInfo != null) {
                getSystemService(SmsManager::class.java)
                    .createForSubscriptionId(subscriptionInfo.subscriptionId)
            } else {
                getSystemService(SmsManager::class.java)
            }
        } else {
            SmsManager.getDefault()
        }

        val parts = smsManager.divideMessage(message)
        if (parts.size > 1) {
            smsManager.sendMultipartTextMessage(phone, null, ArrayList(parts), null, null)
        } else {
            smsManager.sendTextMessage(phone, null, message, null, null)
        }
    }

    private fun showSmsNotification(
        sender: String,
        body: String,
        isSuspicious: Boolean,
        timestamp: Long
    ) {
        val safeChannelId = "sms_safe_channel"
        val suspiciousChannelId = "sms_suspicious_channel"
        val notifManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notifManager.createNotificationChannel(
                NotificationChannel(
                    safeChannelId,
                    "SMS Messages",
                    NotificationManager.IMPORTANCE_HIGH
                )
            )

            notifManager.createNotificationChannel(
                NotificationChannel(
                    suspiciousChannelId,
                    "Suspicious Messages",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    setShowBadge(false)
                }
            )
        }

        val notificationKey = "$sender|$timestamp|${body.hashCode()}"
        val openAppIntent = PendingIntent.getActivity(
            this,
            notificationKey.hashCode(),
            Intent(this, MainActivity::class.java).apply {
                action = ACTION_OPEN_SMS_NOTIFICATION
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("sender", sender)
                putExtra("body", body)
                putExtra("timestamp", timestamp)
                putExtra("notificationKey", notificationKey)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val channelId = if (isSuspicious) suspiciousChannelId else safeChannelId
        val senderDisplay = ContactNameResolver.resolveDisplayName(this, sender)
        val title = if (isSuspicious) "⚠️ Suspicious Message Blocked" else sender
        val content = if (isSuspicious) {
            "A suspicious message was blocked and moved to Quarantine Vault."
        } else {
            body
        }

        val notif = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(
                if (isSuspicious) "Suspicious message from $senderDisplay" else senderDisplay
            )
            .setContentText(content)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent)
            .build()

        notifManager.notify(notificationKey.hashCode(), notif)
    }

    private fun showChatNotification(
        chatId: String,
        messageId: String,
        senderId: String,
        sender: String,
        body: String
    ) {
        if (chatId.isBlank() || messageId.isBlank() || senderId.isBlank()) {
            Log.w(TAG, "Skipping chat notification without routing metadata")
            return
        }

        ChatNotificationHelper.showChatNotification(
            context = this,
            chatId = chatId,
            messageId = messageId,
            senderId = senderId,
            senderName = sender,
            body = body
        )
    }

    private fun saveChatNotificationPreferences(
        mutedSenderIds: Set<String>,
        blockedSenderIds: Set<String>
    ) {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putStringSet(PREF_MUTED_CHAT_SENDERS, mutedSenderIds)
            .putStringSet(PREF_BLOCKED_CHAT_SENDERS, blockedSenderIds)
            .apply()
    }

    private fun showFriendRequestNotification(senderId: String, sender: String) {
        val channelId = "friend_request_channel"
        val notifManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notifManager.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    "Friend Requests",
                    NotificationManager.IMPORTANCE_HIGH
                )
            )
        }

        val openAppIntent = PendingIntent.getActivity(
            this,
            senderId.hashCode(),
            Intent(this, MainActivity::class.java).apply {
                action = ACTION_OPEN_FRIEND_REQUEST_NOTIFICATION
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("senderId", senderId)
                putExtra("senderName", sender)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notif = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("New friend request")
            .setContentText("$sender sent you a friend request")
            .setAutoCancel(true)
            .setContentIntent(openAppIntent)
            .build()

        notifManager.notify("friend_request_$senderId".hashCode(), notif)
    }

    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < 34) {
            return true
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        return notificationManager?.canUseFullScreenIntent() ?: false
    }

    private fun openFullScreenIntentSettings() {
        val intent =
            if (Build.VERSION.SDK_INT >= 34) {
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                    data = Uri.parse("package:$packageName")
                }
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
            }

        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun openIncomingCallChannelSettings() {
        val intent =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    putExtra(
                        Settings.EXTRA_CHANNEL_ID,
                        CallNotificationHelper.INCOMING_CALL_CHANNEL_ID
                    )
                }
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
            }

        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun startRingtone() {
        try {
            stopRingtone()
            prepareIncomingRingtoneAudio()

            val notification: Uri =
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)

            ringtonePlayer = MediaPlayer().apply {
                setDataSource(applicationContext, notification)
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error playing ringtone: ${e.message}", e)
        }
    }

    private fun getSimSlots(): List<Map<String, Any>> {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                val subscriptionManager = getSystemService(SubscriptionManager::class.java)
                val subscriptions = subscriptionManager?.activeSubscriptionInfoList ?: emptyList()

                if (subscriptions.isEmpty()) {
                    listOf(mapOf("slotIndex" to 0, "displayName" to "SIM1"))
                } else {
                    subscriptions.sortedBy { it.simSlotIndex }.map { info ->
                        val name = when {
                            !info.displayName.isNullOrBlank() -> info.displayName.toString()
                            !info.carrierName.isNullOrBlank() -> info.carrierName.toString()
                            else -> "SIM${info.simSlotIndex + 1}"
                        }
                        mapOf(
                            "slotIndex" to info.simSlotIndex,
                            "displayName" to name
                        )
                    }
                }
            } else {
                listOf(mapOf("slotIndex" to 0, "displayName" to "SIM1"))
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load SIM slots: ${e.message}", e)
            listOf(mapOf("slotIndex" to 0, "displayName" to "SIM1"))
        }
    }

    private fun stopRingtone() {
        try {
            ringtonePlayer?.stop()
        } catch (_: Exception) {
        }

        try {
            ringtonePlayer?.release()
        } catch (_: Exception) {
        }

        ringtonePlayer = null
    }

    private fun startOutgoingRingtone() {
        try {
            stopOutgoingRingtone()
            val gen = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 80)
            outgoingToneGenerator = gen
            val handler = Handler(Looper.getMainLooper())
            outgoingToneHandler = handler
            val runnable = object : Runnable {
                override fun run() {
                    if (outgoingToneGenerator == null) return
                    try {
                        outgoingToneGenerator?.startTone(ToneGenerator.TONE_SUP_RINGTONE, 1000)
                    } catch (_: Exception) {}
                    outgoingToneHandler?.postDelayed(this, 4000)
                }
            }
            handler.post(runnable)
        } catch (e: Exception) {
            Log.e(TAG, "Error starting outgoing ringtone: ${e.message}", e)
        }
    }

    private fun stopOutgoingRingtone() {
        outgoingToneHandler?.removeCallbacksAndMessages(null)
        outgoingToneHandler = null
        try { outgoingToneGenerator?.stopTone() } catch (_: Exception) {}
        try { outgoingToneGenerator?.release() } catch (_: Exception) {}
        outgoingToneGenerator = null
    }

    private fun prepareIncomingRingtoneAudio() {
        val audioManager = getSystemService(AUDIO_SERVICE) as? AudioManager ?: return

        abandonCallAudioFocus(audioManager)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice()
            }
        } catch (_: Exception) {
        }

        try {
            audioManager.stopBluetoothSco()
        } catch (_: Exception) {
        }

        try {
            @Suppress("DEPRECATION")
            audioManager.isBluetoothScoOn = false
        } catch (_: Exception) {
        }

        try {
            audioManager.mode = AudioManager.MODE_NORMAL
        } catch (_: Exception) {
        }

        try {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = true
        } catch (_: Exception) {
        }

        try {
            audioManager.isMicrophoneMute = false
        } catch (_: Exception) {
        }
    }

    private fun resetCallAudioState() {
        stopRingtone()
        stopOutgoingRingtone()
        prepareIncomingRingtoneAudio()
    }

    private fun prepareCallAudioState(speaker: Boolean) {
        val audioManager = getSystemService(AUDIO_SERVICE) as? AudioManager ?: return

        requestCallAudioFocus(audioManager)

        try {
            stopRingtone()
        } catch (_: Exception) {
        }

        try {
            stopOutgoingRingtone()
        } catch (_: Exception) {
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice()
            }
        } catch (_: Exception) {
        }

        try {
            audioManager.stopBluetoothSco()
        } catch (_: Exception) {
        }

        try {
            @Suppress("DEPRECATION")
            audioManager.isBluetoothScoOn = false
        } catch (_: Exception) {
        }

        try {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        } catch (_: Exception) {
        }

        try {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = speaker
        } catch (_: Exception) {
        }

        try {
            audioManager.isMicrophoneMute = false
        } catch (_: Exception) {
        }

        setCommunicationDevice(audioManager, speaker)
    }

    private fun setSpeakerphoneOn(speaker: Boolean) {
        val audioManager = getSystemService(AUDIO_SERVICE) as? AudioManager ?: return
        requestCallAudioFocus(audioManager)

        try {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        } catch (_: Exception) {
        }

        try {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = speaker
        } catch (_: Exception) {
        }

        try {
            audioManager.isMicrophoneMute = false
        } catch (_: Exception) {
        }

        setCommunicationDevice(audioManager, speaker)
    }

    private fun setCommunicationDevice(audioManager: AudioManager, speaker: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return
        }

        try {
            audioManager.clearCommunicationDevice()
        } catch (_: Exception) {
        }

        try {
            val targetType =
                if (speaker) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                else AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            val targetDevice = audioManager.availableCommunicationDevices.firstOrNull {
                it.type == targetType
            }
            if (targetDevice != null) {
                audioManager.setCommunicationDevice(targetDevice)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to select communication device: ${e.message}", e)
        }
    }

    private fun requestCallAudioFocus(audioManager: AudioManager) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request =
                    callAudioFocusRequest
                        ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                            .setAudioAttributes(
                                AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                    .build()
                            )
                            .setOnAudioFocusChangeListener { }
                            .build()

                callAudioFocusRequest = request
                audioManager.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    null,
                    AudioManager.STREAM_VOICE_CALL,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to request call audio focus: ${e.message}", e)
        }
    }

    private fun abandonCallAudioFocus(audioManager: AudioManager) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                callAudioFocusRequest?.let { request ->
                    audioManager.abandonAudioFocusRequest(request)
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to abandon call audio focus: ${e.message}", e)
        }
    }

    private fun supportsPictureInPicture(): Boolean {
        return packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun isCurrentlyInPictureInPictureMode(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            isInPictureInPictureMode
        } else {
            false
        }
    }

    private fun setVideoCallPictureInPictureEnabled(enabled: Boolean) {
        videoCallPictureInPictureEnabled = enabled

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !supportsPictureInPicture()) {
            return
        }

        try {
            setPictureInPictureParams(buildPictureInPictureParams(enabled))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to update PiP params: ${e.message}", e)
        }
    }

    private fun buildPictureInPictureParams(autoEnterEnabled: Boolean): android.app.PictureInPictureParams {
        val builder = android.app.PictureInPictureParams.Builder()
            .setAspectRatio(DEFAULT_PIP_RATIO)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder
                .setAutoEnterEnabled(autoEnterEnabled)
                .setSeamlessResizeEnabled(autoEnterEnabled)
        }

        return builder.build()
    }

    private fun enterPictureInPictureInternal(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }

        if (!supportsPictureInPicture()) {
            return false
        }

        if (!videoCallPictureInPictureEnabled) {
            return false
        }

        return try {
            enterPictureInPictureMode(buildPictureInPictureParams(true))
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to enter picture-in-picture: ${e.message}", e)
            false
        }
    }

    private fun enterPictureInPicture(): Boolean {
        return enterPictureInPictureInternal()
    }
}
