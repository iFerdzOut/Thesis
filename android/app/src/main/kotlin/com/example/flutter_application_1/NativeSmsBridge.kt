package com.example.flutter_application_1

import android.app.ActivityManager
import android.app.Activity
import android.app.role.RoleManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Settings
import android.provider.Telephony
import android.telephony.SubscriptionManager
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class NativeSmsBridge(
    private val activity: MainActivity,
    private val channel: MethodChannel
) {
    companion object {
        private const val TAG = "NativeSmsBridge"
        private const val REQUEST_CODE_DEFAULT_SMS = 1001
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "isDefaultSmsApp" -> {
                result.success(isDefaultSmsApp())
                return true
            }
            "getSmsCapabilityState" -> {
                result.success(getCapabilityState())
                return true
            }
            "getDevicePerformanceProfile" -> {
                result.success(getDevicePerformanceProfile())
                return true
            }
            "requestDefaultSmsApp" -> {
                requestDefaultSmsApp()
                result.success(null)
                return true
            }
            "openDefaultSmsSettings" -> {
                openDefaultSmsSettings()
                result.success(null)
                return true
            }
            "getSmsThreads" -> {
                val limit = call.argument<Number>("limit")?.toInt() ?: 200
                try {
                    result.success(SmsSyncManager.queryThreads(activity, limit))
                } catch (error: Exception) {
                    Log.e(TAG, "getSmsThreads failed: ${error.message}", error)
                    result.success(emptyList<Map<String, Any?>>())
                }
                return true
            }
            "getSmsMessages" -> {
                val threadId = call.argument<Any?>("threadId")?.toString()?.toLongOrNull()
                val address = call.argument<String>("address")
                val limit = call.argument<Number>("limit")?.toInt() ?: 200
                val beforeProviderId =
                    call.argument<Any?>("beforeProviderId")?.toString()?.toLongOrNull()
                val beforeTimestampMs =
                    call.argument<Any?>("beforeTimestampMs")?.toString()?.toLongOrNull()
                try {
                    result.success(
                        SmsSyncManager.queryMessages(
                            context = activity,
                            threadId = threadId,
                            address = address,
                            limit = limit,
                            beforeProviderId = beforeProviderId,
                            beforeTimestampMs = beforeTimestampMs
                        )
                    )
                } catch (error: Exception) {
                    Log.e(TAG, "getSmsMessages failed: ${error.message}", error)
                    result.success(emptyList<Map<String, Any?>>())
                }
                return true
            }
            "sendSms", "sendSMS" -> {
                val address = call.argument<String>("address")
                    ?: call.argument<String>("phone")
                val body = call.argument<String>("body")
                    ?: call.argument<String>("message")
                val simSlot = call.argument<Int>("simSlot") ?: 0

                if (address.isNullOrBlank() || body.isNullOrBlank()) {
                    result.error("invalid_args", "Address/body is required", null)
                    return true
                }

                try {
                    result.success(
                        SmsPlatformSender.sendTextMessage(
                            context = activity,
                            address = address,
                            body = body,
                            simSlot = simSlot
                        )
                    )
                } catch (error: Exception) {
                    result.error("sms_send_failed", error.message, null)
                }
                return true
            }
            "syncSmsNow" -> {
                try {
                    result.success(
                        SmsSyncManager.syncThreadSummaries(
                            context = activity,
                            limit = call.argument<Number>("threadLimit")?.toInt()
                                ?: if (call.argument<Boolean>("fullHistory") == true) 500 else 200,
                            sinceTimestampMs = call.argument<Any?>("sinceTimestampMs")
                                ?.toString()
                                ?.toLongOrNull(),
                            sinceProviderId = call.argument<Any?>("sinceProviderId")
                                ?.toString()
                                ?.toLongOrNull(),
                            fullHistory = call.argument<Boolean>("fullHistory") == true
                        )
                    )
                } catch (error: Exception) {
                    Log.e(TAG, "syncSmsNow failed: ${error.message}", error)
                    result.success(
                        mapOf(
                            "threads" to emptyList<Map<String, Any?>>(),
                            "changedThreadIds" to emptyList<String>(),
                            "latestTimestampMs" to 0,
                            "latestProviderId" to 0,
                            "threadCount" to 0
                        )
                    )
                }
                return true
            }
            "consumePendingSmsEvents" -> {
                result.success(SmsEventStore.consumeEvents(activity))
                return true
            }
            "deleteProviderSms" -> {
                val providerId = call.argument<Any?>("providerId")?.toString()?.toLongOrNull()
                result.success(
                    if (providerId == null) {
                        false
                    } else {
                        SmsSyncManager.deleteMessageById(activity, providerId)
                    }
                )
                return true
            }
            "getSimSlots" -> {
                result.success(getSimSlots())
                return true
            }
            "openDialer" -> {
                openDialer(call.argument<String>("phone").orEmpty())
                result.success(null)
                return true
            }
            "openAddContact" -> {
                openAddContact(
                    phone = call.argument<String>("phone").orEmpty(),
                    name = call.argument<String>("name").orEmpty()
                )
                result.success(null)
                return true
            }
        }
        return false
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_CODE_DEFAULT_SMS) {
            return false
        }
        val payload = getCapabilityState() + mapOf(
            "accepted" to (resultCode == Activity.RESULT_OK)
        )
        SmsFlutterDispatcher.dispatchOrQueue(
            context = activity,
            method = "onSmsRoleChanged",
            eventType = "roleChanged",
            payload = payload
        )
        return true
    }

    fun handleIntent(intent: Intent?): Boolean {
        if (intent == null) {
            return false
        }
        if (intent.action != SmsIntentActions.ACTION_OPEN_SMS_COMPOSE) {
            return false
        }

        val phone = intent.getStringExtra(SmsIntentActions.EXTRA_PHONE).orEmpty()
        val body = intent.getStringExtra(SmsIntentActions.EXTRA_BODY).orEmpty()
        val sourceAction = intent.getStringExtra(SmsIntentActions.EXTRA_SOURCE_ACTION).orEmpty()
        if (phone.isBlank()) {
            return true
        }

        val payload = mapOf(
            "phone" to phone,
            "body" to body,
            "sourceAction" to sourceAction
        )
        SmsEventStore.queueEvent(
            context = activity,
            eventType = "composeIntent",
            payload = payload
        )
        SmsFlutterDispatcher.dispatch("onSmsComposeIntentReceived", payload)
        return true
    }

    private fun getCapabilityState(): Map<String, Any> {
        val readGranted =
            activity.checkSelfPermission(android.Manifest.permission.READ_SMS) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        val sendGranted =
            activity.checkSelfPermission(android.Manifest.permission.SEND_SMS) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        val receiveGranted =
            activity.checkSelfPermission(android.Manifest.permission.RECEIVE_SMS) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED

        val roleAvailable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = activity.getSystemService(RoleManager::class.java)
            roleManager?.isRoleAvailable(RoleManager.ROLE_SMS) == true
        } else {
            true
        }
        val roleHeld = isDefaultSmsApp()

        return mapOf(
            "isDefault" to roleHeld,
            "roleAvailable" to roleAvailable,
            "roleHeld" to roleHeld,
            "readSmsGranted" to readGranted,
            "sendSmsGranted" to sendGranted,
            "receiveSmsGranted" to receiveGranted,
            "canUseSmsFeatures" to (roleHeld && readGranted && sendGranted)
        )
    }

    private fun getDevicePerformanceProfile(): Map<String, Any> {
        val activityManager =
            activity.getSystemService(Activity.ACTIVITY_SERVICE) as? ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo()
        activityManager?.getMemoryInfo(memoryInfo)

        val totalRamMb =
            if (memoryInfo.totalMem > 0L) {
                (memoryInfo.totalMem / (1024L * 1024L)).toInt()
            } else {
                0
            }

        return mapOf(
            "isLowRamDevice" to (activityManager?.isLowRamDevice ?: false),
            "memoryClassMb" to (activityManager?.memoryClass ?: 0),
            "largeMemoryClassMb" to (activityManager?.largeMemoryClass ?: 0),
            "totalRamMb" to totalRamMb
        )
    }

    private fun isDefaultSmsApp(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = activity.getSystemService(RoleManager::class.java)
            roleManager?.isRoleHeld(RoleManager.ROLE_SMS) == true
        } else {
            Telephony.Sms.getDefaultSmsPackage(activity) == activity.packageName
        }
    }

    private fun requestDefaultSmsApp() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = activity.getSystemService(RoleManager::class.java)
            val available = roleManager?.isRoleAvailable(RoleManager.ROLE_SMS) == true
            if (!available) {
                openDefaultSmsSettings()
                return
            }
            try {
                activity.startActivityForResult(
                    roleManager!!.createRequestRoleIntent(RoleManager.ROLE_SMS),
                    REQUEST_CODE_DEFAULT_SMS
                )
            } catch (error: Exception) {
                Log.e(TAG, "Role request failed: ${error.message}", error)
                openDefaultSmsSettings()
            }
            return
        }

        try {
            activity.startActivityForResult(
                Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT).apply {
                    putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, activity.packageName)
                },
                REQUEST_CODE_DEFAULT_SMS
            )
        } catch (error: Exception) {
            Log.e(TAG, "Legacy default SMS request failed: ${error.message}", error)
            openDefaultSmsSettings()
        }
    }

    private fun openDefaultSmsSettings() {
        val intent =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${activity.packageName}")
                }
            }

        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(intent)
    }

    private fun openDialer(phone: String) {
        val uri = if (phone.trim().isNotEmpty()) {
            Uri.parse("tel:${phone.trim()}")
        } else {
            Uri.parse("tel:")
        }
        activity.startActivity(
            Intent(Intent.ACTION_DIAL, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }

    private fun openAddContact(phone: String, name: String) {
        activity.startActivity(
            Intent(ContactsContract.Intents.Insert.ACTION).apply {
                type = ContactsContract.RawContacts.CONTENT_TYPE
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (phone.trim().isNotEmpty()) {
                    putExtra(ContactsContract.Intents.Insert.PHONE, phone.trim())
                }
                if (name.trim().isNotEmpty() && name.trim() != phone.trim()) {
                    putExtra(ContactsContract.Intents.Insert.NAME, name.trim())
                }
            }
        )
    }

    private fun getSimSlots(): List<Map<String, Any>> {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                val subscriptionManager = activity.getSystemService(SubscriptionManager::class.java)
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
        } catch (error: Exception) {
            Log.e(TAG, "Failed to load SIM slots: ${error.message}", error)
            listOf(mapOf("slotIndex" to 0, "displayName" to "SIM1"))
        }
    }
}
