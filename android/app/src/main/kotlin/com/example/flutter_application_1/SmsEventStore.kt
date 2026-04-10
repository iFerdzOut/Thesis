package com.example.flutter_application_1

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

object SmsEventStore {
    private const val TAG = "SmsEventStore"
    private const val PREFS_NAME = "sms_native_event_store"
    private const val KEY_PENDING_EVENTS = "pending_events"
    private const val MAX_PENDING_EVENTS = 128

    fun queueEvent(
        context: Context,
        eventType: String,
        payload: Map<String, Any?>
    ) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val existing = JSONArray(prefs.getString(KEY_PENDING_EVENTS, "[]") ?: "[]")
            val entry = JSONObject()
                .put("eventType", eventType)
                .put("payload", payload.toJson())
            existing.put(entry)

            val trimmed = JSONArray()
            val startIndex = maxOf(0, existing.length() - MAX_PENDING_EVENTS)
            for (index in startIndex until existing.length()) {
                trimmed.put(existing.get(index))
            }

            prefs.edit().putString(KEY_PENDING_EVENTS, trimmed.toString()).apply()
        } catch (error: Exception) {
            Log.e(TAG, "Failed to queue SMS event: ${error.message}", error)
        }
    }

    fun consumeEvents(context: Context): List<Map<String, Any?>> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_PENDING_EVENTS, "[]") ?: "[]"
        prefs.edit().remove(KEY_PENDING_EVENTS).apply()

        return try {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val payload = item.optJSONObject("payload")?.toMap() ?: emptyMap()
                    add(payload + mapOf("eventType" to item.optString("eventType")))
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "Failed to consume SMS events: ${error.message}", error)
            emptyList()
        }
    }

    private fun Map<String, Any?>.toJson(): JSONObject {
        val json = JSONObject()
        for ((key, value) in this) {
            json.put(key, value.toJsonValue())
        }
        return json
    }

    private fun Any?.toJsonValue(): Any? {
        return when (this) {
            null -> JSONObject.NULL
            is Map<*, *> -> {
                val json = JSONObject()
                for ((key, value) in this) {
                    if (key != null) {
                        json.put(key.toString(), value.toJsonValue())
                    }
                }
                json
            }
            is Iterable<*> -> {
                val array = JSONArray()
                for (value in this) {
                    array.put(value.toJsonValue())
                }
                array
            }
            is Array<*> -> {
                val array = JSONArray()
                for (value in this) {
                    array.put(value.toJsonValue())
                }
                array
            }
            else -> this
        }
    }

    private fun JSONObject.toMap(): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        val keys = keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = get(key).fromJsonValue()
        }
        return result
    }

    private fun Any?.fromJsonValue(): Any? {
        return when (this) {
            JSONObject.NULL -> null
            is JSONObject -> toMap()
            is JSONArray -> buildList<Any?> {
                for (index in 0 until length()) {
                    add(get(index).fromJsonValue())
                }
            }
            else -> this
        }
    }
}
