package com.example.flutter_application_1

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.provider.Telephony
import android.telephony.PhoneNumberUtils

object SmsSyncManager {
    private const val COLUMN_SUBSCRIPTION_ID = "sub_id"
    private const val FALLBACK_QUERY_LIMIT = 1000
    private const val DEFAULT_THREAD_SCAN_LIMIT = 500

    private val smsProjection = arrayOf(
        Telephony.Sms._ID,
        Telephony.Sms.THREAD_ID,
        Telephony.Sms.ADDRESS,
        Telephony.Sms.BODY,
        Telephony.Sms.DATE,
        Telephony.Sms.DATE_SENT,
        Telephony.Sms.TYPE,
        Telephony.Sms.READ,
        Telephony.Sms.STATUS,
        COLUMN_SUBSCRIPTION_ID
    )

    fun buildIngressKey(
        address: String,
        body: String,
        timestamp: Long,
        subscriptionId: Int?
    ): String {
        return "${normalizePhone(address)}|$timestamp|${body.hashCode()}|${subscriptionId ?: -1}"
    }

    fun queryThreads(context: Context, limit: Int): List<Map<String, Any?>> {
        val rows = mutableListOf<Map<String, Any?>>()
        val unreadByThread = mutableMapOf<String, Int>()
        val latestByThread = linkedMapOf<String, Map<String, Any?>>()
        val rowLimit = if (limit >= 1000) limit else maxOf(limit * 25, 500)

        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            smsProjection,
            null,
            null,
            "${Telephony.Sms.DATE} DESC LIMIT $rowLimit"
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val row = cursor.toSmsRow()
                val threadKey = row.canonicalThreadKey()
                if (threadKey.isBlank()) continue

                if (!latestByThread.containsKey(threadKey)) {
                    latestByThread[threadKey] = row.toThreadMap(context)
                }
                if (!row.isOutgoing && !row.isRead) {
                    unreadByThread[threadKey] = (unreadByThread[threadKey] ?: 0) + 1
                }
                if (latestByThread.size >= limit) {
                    break
                }
            }
        }

        for ((threadKey, summary) in latestByThread) {
            rows += summary + mapOf("unread" to (unreadByThread[threadKey] ?: 0))
        }
        return rows
    }

    fun queryMessages(
        context: Context,
        threadId: Long?,
        address: String?,
        limit: Int,
        beforeProviderId: Long?,
        beforeTimestampMs: Long?
    ): List<Map<String, Any?>> {
        val rows = mutableListOf<Map<String, Any?>>()

        if (threadId != null) {
            val selectionParts = mutableListOf("${Telephony.Sms.THREAD_ID}=?")
            val selectionArgs = mutableListOf(threadId.toString())
            if (beforeTimestampMs != null && beforeTimestampMs > 0) {
                selectionParts += "${Telephony.Sms.DATE}<?"
                selectionArgs += beforeTimestampMs.toString()
            }
            if (beforeProviderId != null && beforeProviderId > 0) {
                selectionParts += "${Telephony.Sms._ID}<?"
                selectionArgs += beforeProviderId.toString()
            }

            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                smsProjection,
                selectionParts.joinToString(" AND "),
                selectionArgs.toTypedArray(),
                "${Telephony.Sms.DATE} DESC LIMIT $limit"
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    rows += cursor.toSmsRow().toMessageMap()
                }
            }
            return rows.reversed()
        }

        val normalizedTarget = normalizePhone(address ?: "")
        if (normalizedTarget.isBlank()) {
            return emptyList()
        }

        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            smsProjection,
            null,
            null,
            "${Telephony.Sms.DATE} DESC LIMIT ${maxOf(limit * 4, FALLBACK_QUERY_LIMIT)}"
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val row = cursor.toSmsRow()
                if (!addressesMatch(normalizedTarget, row.address.orEmpty())) {
                    continue
                }
                if (beforeTimestampMs != null && row.timestampMs >= beforeTimestampMs) {
                    continue
                }
                if (beforeProviderId != null && (row.providerId ?: Long.MAX_VALUE) >= beforeProviderId) {
                    continue
                }
                rows += row.toMessageMap()
                if (rows.size >= limit) {
                    break
                }
            }
        }

        return rows.reversed()
    }

    fun syncThreadSummaries(
        context: Context,
        limit: Int,
        sinceTimestampMs: Long?,
        sinceProviderId: Long?,
        fullHistory: Boolean
    ): Map<String, Any?> {
        val useFullHistory =
            fullHistory || ((sinceTimestampMs ?: 0L) <= 0L && (sinceProviderId ?: 0L) <= 0L)

        if (useFullHistory) {
            val threads = queryThreads(context, limit)
            val latest = queryLatestCursor(context)
            return mapOf(
                "threads" to threads,
                "changedThreadIds" to threads.mapNotNull { it["threadId"]?.toString() },
                "latestTimestampMs" to latest.first,
                "latestProviderId" to latest.second,
                "threadCount" to threads.size
            )
        }

        val window = scanRecentWindow(
            context = context,
            sinceTimestampMs = sinceTimestampMs ?: 0L,
            sinceProviderId = sinceProviderId ?: 0L,
            limit = maxOf(limit * 20, DEFAULT_THREAD_SCAN_LIMIT)
        )
        if (window.changedThreadIds.isEmpty()) {
            return mapOf(
                "threads" to emptyList<Map<String, Any?>>(),
                "changedThreadIds" to emptyList<String>(),
                "latestTimestampMs" to window.latestTimestampMs,
                "latestProviderId" to window.latestProviderId,
                "threadCount" to 0
            )
        }

        val threads = queryThreadsByIds(
            context = context,
            threadIds = window.changedThreadIds,
            limit = limit
        )
        return mapOf(
            "threads" to threads,
            "changedThreadIds" to window.changedThreadIds.toList(),
            "latestTimestampMs" to window.latestTimestampMs,
            "latestProviderId" to window.latestProviderId,
            "threadCount" to threads.size
        )
    }

    fun insertIncomingMessage(
        context: Context,
        address: String,
        body: String,
        timestamp: Long,
        subscriptionId: Int?
    ): Map<String, Any?> {
        val existing = findExistingMessage(
            context = context,
            address = address,
            body = body,
            timestamp = timestamp,
            messageType = Telephony.Sms.MESSAGE_TYPE_INBOX
        )
        if (existing != null) {
            return existing.toEventMap()
        }

        val values = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, address)
            put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, timestamp)
            put(Telephony.Sms.READ, 0)
            put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_INBOX)
            put(Telephony.Sms.STATUS, Telephony.Sms.STATUS_NONE)
            if (subscriptionId != null && subscriptionId >= 0) {
                put(COLUMN_SUBSCRIPTION_ID, subscriptionId)
            }
        }

        val uri = context.contentResolver.insert(Telephony.Sms.Inbox.CONTENT_URI, values)
        val providerId = uri?.lastPathSegment?.toLongOrNull()
        val inserted = if (providerId != null) queryMessageById(context, providerId) else null
        return inserted?.toEventMap() ?: mapOf("providerId" to providerId, "threadId" to null)
    }

    fun insertOutgoingPendingMessage(
        context: Context,
        address: String,
        body: String,
        timestamp: Long,
        subscriptionId: Int?
    ): Map<String, Any?> {
        val values = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, address)
            put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, timestamp)
            put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_OUTBOX)
            put(Telephony.Sms.READ, 1)
            put(Telephony.Sms.STATUS, Telephony.Sms.STATUS_PENDING)
            if (subscriptionId != null && subscriptionId >= 0) {
                put(COLUMN_SUBSCRIPTION_ID, subscriptionId)
            }
        }

        val uri = context.contentResolver.insert(Telephony.Sms.Outbox.CONTENT_URI, values)
        val providerId = uri?.lastPathSegment?.toLongOrNull()
        val inserted = if (providerId != null) queryMessageById(context, providerId) else null
        return inserted?.toEventMap() ?: mapOf("providerId" to providerId, "threadId" to null)
    }

    fun updateOutgoingStatus(
        context: Context,
        providerId: Long,
        status: String,
        sentAt: Long = System.currentTimeMillis()
    ): Boolean {
        val values = ContentValues().apply {
            when (status) {
                "sending" -> {
                    put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_OUTBOX)
                    put(Telephony.Sms.STATUS, Telephony.Sms.STATUS_PENDING)
                }
                "sent" -> {
                    put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_SENT)
                    put(Telephony.Sms.STATUS, Telephony.Sms.STATUS_NONE)
                    put(Telephony.Sms.DATE_SENT, sentAt)
                    put(Telephony.Sms.READ, 1)
                }
                "delivered" -> {
                    put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_SENT)
                    put(Telephony.Sms.STATUS, Telephony.Sms.STATUS_COMPLETE)
                    put(Telephony.Sms.DATE_SENT, sentAt)
                    put(Telephony.Sms.READ, 1)
                }
                "failed" -> {
                    put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_FAILED)
                    put(Telephony.Sms.STATUS, Telephony.Sms.STATUS_FAILED)
                    put(Telephony.Sms.DATE_SENT, sentAt)
                }
            }
        }

        val updated = context.contentResolver.update(
            ContentUris.withAppendedId(Telephony.Sms.CONTENT_URI, providerId),
            values,
            null,
            null
        )
        return updated > 0
    }

    fun deleteMessageById(context: Context, providerId: Long): Boolean {
        val deleted = context.contentResolver.delete(
            ContentUris.withAppendedId(Telephony.Sms.CONTENT_URI, providerId),
            null,
            null
        )
        return deleted > 0
    }

    fun queryMessageById(context: Context, providerId: Long): SmsRow? {
        return context.contentResolver.query(
            ContentUris.withAppendedId(Telephony.Sms.CONTENT_URI, providerId),
            smsProjection,
            null,
            null,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.toSmsRow()
            } else {
                null
            }
        }
    }

    fun normalizePhone(raw: String): String {
        val compact = raw.trim().replace(Regex("[^0-9+]"), "")
        return when {
            compact.startsWith("+63") && compact.length > 3 -> "0${compact.substring(3)}"
            compact.startsWith("63") && compact.length > 2 -> "0${compact.substring(2)}"
            else -> compact
        }
    }

    private fun findExistingMessage(
        context: Context,
        address: String,
        body: String,
        timestamp: Long,
        messageType: Int
    ): SmsRow? {
        return context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            smsProjection,
            "${Telephony.Sms.ADDRESS}=? AND ${Telephony.Sms.DATE}=? AND ${Telephony.Sms.BODY}=? AND ${Telephony.Sms.TYPE}=?",
            arrayOf(address, timestamp.toString(), body, messageType.toString()),
            "${Telephony.Sms._ID} DESC LIMIT 1"
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.toSmsRow()
            } else {
                null
            }
        }
    }

    private fun addressesMatch(target: String, candidate: String): Boolean {
        val normalizedCandidate = normalizePhone(candidate)
        if (normalizedCandidate.isBlank()) {
            return false
        }
        return normalizedCandidate == target ||
            normalizedCandidate.takeLast(10) == target.takeLast(10) ||
            runCatching { PhoneNumberUtils.compare(target, normalizedCandidate) }.getOrDefault(false)
    }

    private fun Cursor.toSmsRow(): SmsRow {
        return SmsRow(
            providerId = getLongOrNull(Telephony.Sms._ID),
            threadId = getLongOrNull(Telephony.Sms.THREAD_ID),
            address = getStringOrNull(Telephony.Sms.ADDRESS),
            body = getStringOrNull(Telephony.Sms.BODY).orEmpty(),
            timestampMs = getLongOrNull(Telephony.Sms.DATE) ?: System.currentTimeMillis(),
            dateSentMs = getLongOrNull(Telephony.Sms.DATE_SENT),
            type = getIntOrNull(Telephony.Sms.TYPE) ?: Telephony.Sms.MESSAGE_TYPE_INBOX,
            isRead = (getIntOrNull(Telephony.Sms.READ) ?: 0) == 1,
            statusCode = getIntOrNull(Telephony.Sms.STATUS) ?: Telephony.Sms.STATUS_NONE,
            subscriptionId = getIntOrNull(COLUMN_SUBSCRIPTION_ID)
        )
    }

    private fun Cursor.getStringOrNull(columnName: String): String? {
        val index = getColumnIndex(columnName)
        return if (index >= 0 && !isNull(index)) getString(index) else null
    }

    private fun Cursor.getLongOrNull(columnName: String): Long? {
        val index = getColumnIndex(columnName)
        return if (index >= 0 && !isNull(index)) getLong(index) else null
    }

    private fun Cursor.getIntOrNull(columnName: String): Int? {
        val index = getColumnIndex(columnName)
        return if (index >= 0 && !isNull(index)) getInt(index) else null
    }

    private fun scanRecentWindow(
        context: Context,
        sinceTimestampMs: Long,
        sinceProviderId: Long,
        limit: Int
    ): RecentSyncWindow {
        val changedThreadIds = linkedSetOf<String>()
        var latestTimestampMs = sinceTimestampMs
        var latestProviderId = sinceProviderId

        val selection =
            "(${Telephony.Sms.DATE} > ? OR (${Telephony.Sms.DATE} = ? AND ${Telephony.Sms._ID} > ?))"
        val args = arrayOf(
            sinceTimestampMs.toString(),
            sinceTimestampMs.toString(),
            sinceProviderId.toString()
        )

        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            smsProjection,
            selection,
            args,
            "${Telephony.Sms.DATE} DESC LIMIT $limit"
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val row = cursor.toSmsRow()
                val threadKey = row.canonicalThreadKey()
                if (threadKey.isNotBlank()) {
                    changedThreadIds += threadKey
                }
                if (row.timestampMs > latestTimestampMs) {
                    latestTimestampMs = row.timestampMs
                }
                val providerId = row.providerId ?: 0L
                if (providerId > latestProviderId) {
                    latestProviderId = providerId
                }
            }
        }

        return RecentSyncWindow(
            changedThreadIds = changedThreadIds,
            latestTimestampMs = latestTimestampMs,
            latestProviderId = latestProviderId
        )
    }

    private fun queryThreadsByIds(
        context: Context,
        threadIds: Set<String>,
        limit: Int
    ): List<Map<String, Any?>> {
        if (threadIds.isEmpty()) {
            return emptyList()
        }

        val rows = mutableListOf<Map<String, Any?>>()
        val unreadByThread = mutableMapOf<String, Int>()
        val latestByThread = linkedMapOf<String, Map<String, Any?>>()
        val rowLimit = maxOf(limit * 25, DEFAULT_THREAD_SCAN_LIMIT)

        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            smsProjection,
            null,
            null,
            "${Telephony.Sms.DATE} DESC LIMIT $rowLimit"
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val row = cursor.toSmsRow()
                val threadKey = row.canonicalThreadKey()
                if (threadKey.isBlank() || !threadIds.contains(threadKey)) {
                    continue
                }

                if (!latestByThread.containsKey(threadKey)) {
                    latestByThread[threadKey] = row.toThreadMap(context)
                }
                if (!row.isOutgoing && !row.isRead) {
                    unreadByThread[threadKey] = (unreadByThread[threadKey] ?: 0) + 1
                }
                if (latestByThread.size >= threadIds.size || latestByThread.size >= limit) {
                    break
                }
            }
        }

        for ((threadKey, summary) in latestByThread) {
            rows += summary + mapOf("unread" to (unreadByThread[threadKey] ?: 0))
        }
        return rows
    }

    private fun queryLatestCursor(context: Context): Pair<Long, Long> {
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.DATE),
            null,
            null,
            "${Telephony.Sms.DATE} DESC LIMIT 1"
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val providerId = cursor.getLongOrNull(Telephony.Sms._ID) ?: 0L
                val timestampMs = cursor.getLongOrNull(Telephony.Sms.DATE) ?: 0L
                return Pair(timestampMs, providerId)
            }
        }
        return Pair(0L, 0L)
    }

    data class SmsRow(
        val providerId: Long?,
        val threadId: Long?,
        val address: String?,
        val body: String,
        val timestampMs: Long,
        val dateSentMs: Long?,
        val type: Int,
        val isRead: Boolean,
        val statusCode: Int,
        val subscriptionId: Int?
    ) {
        val isOutgoing: Boolean
            get() = type == Telephony.Sms.MESSAGE_TYPE_SENT ||
                type == Telephony.Sms.MESSAGE_TYPE_OUTBOX ||
                type == Telephony.Sms.MESSAGE_TYPE_FAILED ||
                type == Telephony.Sms.MESSAGE_TYPE_QUEUED

        fun canonicalThreadKey(): String {
            val peer = address.orEmpty()
            val normalized = SmsSyncManager.normalizePhone(peer)
            return if (normalized.isNotBlank()) normalized else (threadId?.toString() ?: "")
        }

        fun toMessageMap(): Map<String, Any?> {
            val peer = address.orEmpty()
            val status = when {
                type == Telephony.Sms.MESSAGE_TYPE_FAILED -> "failed"
                type == Telephony.Sms.MESSAGE_TYPE_OUTBOX ||
                    type == Telephony.Sms.MESSAGE_TYPE_QUEUED -> "sending"
                statusCode == Telephony.Sms.STATUS_COMPLETE -> "delivered"
                type == Telephony.Sms.MESSAGE_TYPE_SENT -> "sent"
                else -> "received"
            }

            return mapOf(
                "messageId" to "provider_${providerId ?: timestampMs}",
                "providerId" to providerId,
                "providerThreadId" to threadId,
                "threadId" to canonicalThreadKey(),
                "sender" to if (isOutgoing) "Me" else peer,
                "receiver" to if (isOutgoing) peer else null,
                "peer" to peer,
                "body" to body,
                "text" to body,
                "time" to java.time.Instant.ofEpochMilli(timestampMs).toString(),
                "timestamp" to java.time.Instant.ofEpochMilli(timestampMs).toString(),
                "timestampMs" to timestampMs,
                "simSlot" to (subscriptionId ?: 0),
                "subscriptionId" to subscriptionId,
                "isOutgoing" to isOutgoing,
                "isSuspicious" to false,
                "status" to status,
                "source" to "telephony_provider"
            )
        }

        fun toThreadMap(context: Context): Map<String, Any?> {
            val peer = address.orEmpty()
            val preview = body.trim().ifEmpty {
                if (isOutgoing) "Sent message" else "New message"
            }
            val threadKey = canonicalThreadKey()
            return mapOf(
                "threadId" to threadKey,
                "providerThreadId" to threadId,
                "sender" to peer,
                "senderDisplay" to ContactNameResolver.resolveDisplayName(context, peer),
                "phone" to peer,
                "lastMessage" to preview,
                "lastTime" to java.time.Instant.ofEpochMilli(timestampMs).toString(),
                "lastTimestampMs" to timestampMs,
                "lastDirection" to if (isOutgoing) "outgoing" else "incoming",
                "lastMessageIsQuarantined" to false,
                "lastMessageIsSuspicious" to false,
                "lastSimSlot" to (subscriptionId ?: 0),
                "unread" to 0
            )
        }

        fun toEventMap(): Map<String, Any?> {
            return mapOf(
                "providerId" to providerId,
                "threadId" to threadId,
                "address" to address,
                "body" to body,
                "timestamp" to timestampMs,
                "simSlot" to (subscriptionId ?: 0),
                "subscriptionId" to subscriptionId
            )
        }
    }

    data class RecentSyncWindow(
        val changedThreadIds: Set<String>,
        val latestTimestampMs: Long,
        val latestProviderId: Long
    )
}
