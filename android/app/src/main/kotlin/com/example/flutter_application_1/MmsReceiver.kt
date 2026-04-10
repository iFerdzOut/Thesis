package com.example.flutter_application_1

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class MmsReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "MmsReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "Received MMS deliver action=${intent.action}")
        // MMS handling is not implemented yet, but the receiver is declared so
        // Android can recognize this app as an SMS/MMS-capable default handler.
    }
}
