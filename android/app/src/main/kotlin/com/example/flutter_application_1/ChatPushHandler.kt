package com.example.flutter_application_1

import android.os.Bundle
import android.util.Log

object ChatPushHandler {

    private const val TAG = "ChatPushHandler"
    private const val DEDUP_WINDOW_MS = 25_000L
    private const val PREFS_NAME = "incoming_call_prefs"
    private const val PREF_MUTED_CHAT_SENDERS = "muted_chat_senders"
    private const val PREF_BLOCKED_CHAT_SENDERS = "blocked_chat_senders"
    private val recentMessageIds = HashMap<String, Long>()

    fun looksLikeChatPush(extras: Bundle?): Boolean {
        if (extras == null) return false

        val type = readString(extras, "type", "gcm.notification.type")?.trim()
        val chatId = readString(extras, "chatId", "gcm.notification.chatId")?.trim()
        val messageId = readString(extras, "messageId", "gcm.notification.messageId")?.trim()

        return type.equals("chat", ignoreCase = true) &&
            !chatId.isNullOrBlank() &&
            !messageId.isNullOrBlank()
    }

    fun handleFromRemoteData(
        context: android.content.Context,
        data: Map<String, String>,
        source: String
    ): Boolean {
        val type = data["type"]?.trim()
        val chatId = data["chatId"]?.trim()
        val messageId = data["messageId"]?.trim()

        if (!type.equals("chat", ignoreCase = true) ||
            chatId.isNullOrBlank() ||
            messageId.isNullOrBlank()
        ) {
            return false
        }

        val senderId = data["senderId"]?.trim().orEmpty()
        val senderName = data["senderName"]?.trim().takeUnless { it.isNullOrBlank() } ?: "New message"
        val preview = data["preview"]?.trim().takeUnless { it.isNullOrBlank() } ?: "New message"

        return dispatchChatNotification(context, chatId, messageId, senderId, senderName, preview, source)
    }

    fun handleFromIntentExtras(
        context: android.content.Context,
        extras: Bundle?,
        source: String
    ): Boolean {
        if (extras == null) return false

        val type = readString(extras, "type", "gcm.notification.type")?.trim()
        val chatId = readString(extras, "chatId", "gcm.notification.chatId")?.trim()
        val messageId = readString(extras, "messageId", "gcm.notification.messageId")?.trim()

        if (!type.equals("chat", ignoreCase = true) ||
            chatId.isNullOrBlank() ||
            messageId.isNullOrBlank()
        ) {
            return false
        }

        val senderId = readString(extras, "senderId", "gcm.notification.senderId").orEmpty()
        val senderName = readString(
            extras,
            "senderName",
            "gcm.notification.senderName",
            "sender_name",
            "title"
        ) ?: "New message"
        val preview = readString(
            extras,
            "preview",
            "gcm.notification.preview",
            "body",
            "gcm.notification.body"
        ) ?: "New message"

        return dispatchChatNotification(context, chatId, messageId, senderId, senderName, preview, source)
    }

    private fun dispatchChatNotification(
        context: android.content.Context,
        chatId: String,
        messageId: String,
        senderId: String,
        senderName: String,
        preview: String,
        source: String
    ): Boolean {
        if (isDuplicate(messageId)) {
            Log.d(TAG, "Duplicate chat push ignored for messageId=$messageId source=$source")
            return true
        }

        if (isSuppressedSender(context, senderId)) {
            Log.d(TAG, "Chat push suppressed for senderId=$senderId source=$source")
            return true
        }

        Log.d(
            TAG,
            "Showing killed/background chat notification source=$source chatId=$chatId messageId=$messageId sender=$senderName"
        )

        ChatNotificationHelper.showChatNotification(
            context = context,
            chatId = chatId,
            messageId = messageId,
            senderId = senderId,
            senderName = senderName,
            body = preview
        )

        return true
    }

    private fun isSuppressedSender(
        context: android.content.Context,
        senderId: String
    ): Boolean {
        if (senderId.isBlank()) return false

        val prefs = context.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
        val mutedSenders = prefs.getStringSet(PREF_MUTED_CHAT_SENDERS, emptySet()) ?: emptySet()
        val blockedSenders = prefs.getStringSet(PREF_BLOCKED_CHAT_SENDERS, emptySet()) ?: emptySet()
        return mutedSenders.contains(senderId) || blockedSenders.contains(senderId)
    }

    private fun isDuplicate(messageId: String): Boolean {
        val now = android.os.SystemClock.elapsedRealtime()
        synchronized(recentMessageIds) {
            val iterator = recentMessageIds.entries.iterator()
            while (iterator.hasNext()) {
                val entry = iterator.next()
                if (now - entry.value > DEDUP_WINDOW_MS) {
                    iterator.remove()
                }
            }

            val lastSeen = recentMessageIds[messageId]
            if (lastSeen != null && now - lastSeen < DEDUP_WINDOW_MS) {
                return true
            }

            recentMessageIds[messageId] = now
            return false
        }
    }

    private fun readString(extras: Bundle, vararg keys: String): String? {
        for (key in keys) {
            val value = extras.get(key)?.toString()?.trim()
            if (!value.isNullOrBlank()) {
                return value
            }
        }
        return null
    }
}
