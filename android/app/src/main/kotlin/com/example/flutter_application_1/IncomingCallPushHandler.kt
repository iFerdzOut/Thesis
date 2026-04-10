package com.example.flutter_application_1

import android.app.ActivityManager
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.firebase.firestore.FirebaseFirestore

object IncomingCallPushHandler {

    private const val TAG = "IncomingCallPush"
    private const val DEDUP_WINDOW_MS = 25_000L
    private val recentCallIds = HashMap<String, Long>()

    fun looksLikeCallPush(extras: Bundle?): Boolean {
        if (extras == null) return false

        val type = readString(extras, "type", "gcm.notification.type")?.trim()
        val callId = readString(extras, "callId", "gcm.notification.callId")?.trim()

        return (
            type.equals("call", ignoreCase = true) ||
                type.equals("incoming_call", ignoreCase = true)
            ) && !callId.isNullOrBlank()
    }

    fun isAppForegroundOrVisible(context: Context): Boolean {
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val myProcess = activityManager
            ?.runningAppProcesses
            ?.firstOrNull { it.pid == android.os.Process.myPid() }

        val importance = myProcess?.importance
        return importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND ||
            importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
    }

    fun isDeviceLocked(context: Context): Boolean {
        val keyguardManager = context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        return keyguardManager?.isKeyguardLocked == true
    }

    fun handleFromRemoteData(
        context: Context,
        data: Map<String, String>,
        source: String
    ): Boolean {
        val type = data["type"]?.trim()
        val callId = data["callId"]?.trim()

        if (!isCallType(type) || callId.isNullOrBlank()) {
            Log.d(TAG, "Ignoring remote data from $source because type=$type callId=$callId")
            return false
        }

        val callerName = resolveCallerNameFromMap(data)
        val isVideo = parseBool(data["isVideo"])
        return handleIncomingCall(context, callId, callerName, isVideo, source)
    }

    fun handleFromIntentExtras(
        context: Context,
        extras: Bundle?,
        source: String
    ): Boolean {
        if (extras == null) {
            Log.d(TAG, "Ignoring extras from $source because extras are null")
            return false
        }

        val type = readString(extras, "type", "gcm.notification.type")?.trim()
        val callId = readString(extras, "callId", "gcm.notification.callId")?.trim()

        if (!isCallType(type) || callId.isNullOrBlank()) {
            Log.d(
                TAG,
                "Ignoring intent extras from $source because type=$type callId=$callId keys=${extras.keySet()}"
            )
            return false
        }

        val callerName = readString(
            extras,
            "callerName",
            "gcm.notification.callerName",
            "caller_name",
            "senderName",
            "sender_name",
            "google.c.a.c_l",
            "title"
        )?.takeIf { it.isNotBlank() } ?: "Unknown Caller"
        val isVideo = parseBool(readString(extras, "isVideo", "gcm.notification.isVideo"))

        return handleIncomingCall(context, callId, callerName, isVideo, source)
    }

    private fun handleIncomingCall(
        context: Context,
        callId: String,
        callerName: String,
        isVideo: Boolean,
        source: String
    ): Boolean {
        if (isDuplicate(callId)) {
            Log.d(TAG, "Duplicate call push ignored for callId=$callId source=$source")
            return true
        }

        if (callerName == "Unknown Caller") {
            FirebaseFirestore.getInstance()
                .collection("calls")
                .document(callId)
                .get()
                .addOnSuccessListener { snapshot ->
                    val callDocCallerName =
                        snapshot.getString("callerName")?.takeIf { it.isNotBlank() }
                            ?: snapshot.getString("caller_name")?.takeIf { it.isNotBlank() }
                            ?: snapshot.getString("senderName")?.takeIf { it.isNotBlank() }
                            ?: snapshot.getString("sender_name")?.takeIf { it.isNotBlank() }
                            ?: snapshot.getString("name")?.takeIf { it.isNotBlank() }
                    val callerId = snapshot.getString("callerId")?.takeIf { it.isNotBlank() }
                    val resolvedIsVideo = snapshot.getBoolean("isVideo") ?: isVideo

                    if (!callDocCallerName.isNullOrBlank() &&
                        !callDocCallerName.equals("unknown caller", ignoreCase = true)
                    ) {
                        dispatchIncomingCall(
                            context = context,
                            callId = callId,
                            callerName = callDocCallerName,
                            isVideo = resolvedIsVideo,
                            source = "$source/firestore"
                        )
                        return@addOnSuccessListener
                    }

                    if (callerId.isNullOrBlank()) {
                        dispatchIncomingCall(
                            context = context,
                            callId = callId,
                            callerName = callerName,
                            isVideo = resolvedIsVideo,
                            source = "$source/firestore_fallback"
                        )
                        return@addOnSuccessListener
                    }

                    FirebaseFirestore.getInstance()
                        .collection("users")
                        .document(callerId)
                        .get()
                        .addOnSuccessListener { userSnapshot ->
                            val resolvedCallerName =
                                userSnapshot.getString("name")?.takeIf { it.isNotBlank() }
                                    ?: userSnapshot.getString("displayName")?.takeIf { it.isNotBlank() }
                                    ?: userSnapshot.getString("email")?.takeIf { it.isNotBlank() }
                                    ?: callerName

                            dispatchIncomingCall(
                                context = context,
                                callId = callId,
                                callerName = resolvedCallerName,
                                isVideo = resolvedIsVideo,
                                source = "$source/user_lookup"
                            )
                        }
                        .addOnFailureListener { error ->
                            Log.w(
                                TAG,
                                "User lookup failed for callId=$callId callerId=$callerId: ${error.message}"
                            )
                            dispatchIncomingCall(
                                context = context,
                                callId = callId,
                                callerName = callerName,
                                isVideo = resolvedIsVideo,
                                source = "$source/user_fallback"
                            )
                        }
                }
                .addOnFailureListener { error ->
                    Log.w(
                        TAG,
                        "Caller name lookup failed for callId=$callId: ${error.message}"
                    )
                    dispatchIncomingCall(
                        context = context,
                        callId = callId,
                        callerName = callerName,
                        isVideo = isVideo,
                        source = "$source/fallback"
                    )
                }
        } else {
            dispatchIncomingCall(
                context = context,
                callId = callId,
                callerName = callerName,
                isVideo = isVideo,
                source = source
            )
        }

        return true
    }

    private fun dispatchIncomingCall(
        context: Context,
        callId: String,
        callerName: String,
        isVideo: Boolean,
        source: String
    ) {
        Log.d(
            TAG,
            "Handling incoming call natively source=$source callId=$callId caller=$callerName isVideo=$isVideo"
        )

        CallNotificationHelper.showIncomingCallNotification(
            context = context,
            callId = callId,
            callerName = callerName,
            isVideo = isVideo
        )

        if (shouldForceIncomingPopup(context)) {
            val popupIntent = Intent(context, IncomingCallActivity::class.java).apply {
                action = IncomingCallActivity.ACTION_OPEN_FROM_NOTIFICATION
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(IncomingCallActivity.EXTRA_CALL_ID, callId)
                putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, callerName)
                putExtra(IncomingCallActivity.EXTRA_IS_VIDEO, isVideo)
                putExtra(IncomingCallActivity.EXTRA_FROM_NOTIFICATION, true)
            }

            launchIncomingPopup(context, popupIntent, callId, attempt = "initial")

            if (isMiuiLikeDevice()) {
                Handler(Looper.getMainLooper()).postDelayed({
                    launchIncomingPopup(context, popupIntent, callId, attempt = "miui_retry")
                }, 1200L)
            }
        } else {
            Log.d(TAG, "Skipping popup launch because app is already foreground")
        }
    }

    private fun isDuplicate(callId: String): Boolean {
        val now = android.os.SystemClock.elapsedRealtime()
        synchronized(recentCallIds) {
            val iterator = recentCallIds.entries.iterator()
            while (iterator.hasNext()) {
                val entry = iterator.next()
                if (now - entry.value > DEDUP_WINDOW_MS) {
                    iterator.remove()
                }
            }

            val lastSeen = recentCallIds[callId]
            if (lastSeen != null && now - lastSeen < DEDUP_WINDOW_MS) {
                return true
            }

            recentCallIds[callId] = now
            return false
        }
    }

    private fun shouldForceIncomingPopup(context: Context): Boolean {
        if (isDeviceLocked(context)) {
            Log.d(TAG, "Popup launch requested because device is locked")
            return true
        }

        val isForeground = isAppForegroundOrVisible(context)
        Log.d(TAG, "Process foreground/visible=$isForeground")
        return !isForeground
    }

    private fun isMiuiLikeDevice(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        return manufacturer.contains("xiaomi") ||
            manufacturer.contains("redmi") ||
            manufacturer.contains("poco") ||
            brand.contains("xiaomi") ||
            brand.contains("redmi") ||
            brand.contains("poco")
    }

    private fun launchIncomingPopup(
        context: Context,
        intent: Intent,
        callId: String,
        attempt: String
    ) {
        try {
            Log.d(TAG, "Launching IncomingCallActivity popup for callId=$callId attempt=$attempt")
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Incoming popup launch failed attempt=$attempt: ${e.message}", e)
        }
    }

    private fun isCallType(type: String?): Boolean {
        return type.equals("call", ignoreCase = true) ||
            type.equals("incoming_call", ignoreCase = true)
    }

    private fun parseBool(value: String?): Boolean {
        if (value == null) return false
        return value.equals("true", ignoreCase = true) ||
            value == "1" ||
            value.equals("yes", ignoreCase = true)
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

    private fun resolveCallerNameFromMap(data: Map<String, String>): String {
        val keys = listOf(
            "callerName",
            "caller_name",
            "senderName",
            "sender_name",
            "name",
            "title"
        )

        for (key in keys) {
            val value = data[key]?.trim()
            if (!value.isNullOrBlank() && !value.equals("unknown caller", ignoreCase = true)) {
                return value
            }
        }

        return "Unknown Caller"
    }
}
