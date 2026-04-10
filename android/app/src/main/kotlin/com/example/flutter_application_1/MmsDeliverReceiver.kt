package com.example.flutter_application_1

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class MmsDeliverReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "MmsDeliverReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "Received MMS action=${intent.action}")
        SmsFlutterDispatcher.dispatchOrQueue(
            context = context,
            method = "onSmsSyncUpdated",
            eventType = "syncUpdated",
            payload = mapOf(
                "reason" to "mms"
            )
        )
    }
}
