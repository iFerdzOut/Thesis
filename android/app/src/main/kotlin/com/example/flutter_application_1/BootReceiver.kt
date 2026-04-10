package com.example.flutter_application_1

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        Log.d(TAG, "onReceive action=$action")

        if (action != Intent.ACTION_BOOT_COMPLETED) return

        // Old call listener service was removed in the rebuild.
        // Nothing needs to restart here for calls now because incoming calls
        // are driven by FCM -> notification -> activity.
        Log.d(TAG, "Boot completed - no call listener service to restart")
    }
}