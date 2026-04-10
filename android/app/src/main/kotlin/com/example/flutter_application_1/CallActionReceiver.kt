package com.example.flutter_application_1

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.firebase.firestore.FirebaseFirestore

class CallActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_ACCEPT_CALL = "com.example.flutter_application_1.ACTION_ACCEPT_CALL"
        const val ACTION_DECLINE_CALL = "com.example.flutter_application_1.ACTION_DECLINE_CALL"
        private const val TAG = "CallActionReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return

        val receivedAction = intent.action
        val callId = intent.getStringExtra(IncomingCallActivity.EXTRA_CALL_ID) ?: ""
        val callerName =
            intent.getStringExtra(IncomingCallActivity.EXTRA_CALLER_NAME) ?: "Unknown Caller"
        val isVideo = intent.getBooleanExtra(IncomingCallActivity.EXTRA_IS_VIDEO, false)

        if (callId.isBlank()) {
            Log.d(TAG, "Missing callId for action=$receivedAction")
            return
        }

        when (receivedAction) {
            ACTION_ACCEPT_CALL -> {
                Log.d(TAG, "Accept clicked for callId=$callId")

                FirebaseFirestore.getInstance()
                    .collection("calls")
                    .document(callId)
                    .update("status", "accepted")
                    .addOnSuccessListener {
                        Log.d(TAG, "Firestore accepted update success for callId=$callId")
                    }
                    .addOnFailureListener { e ->
                        Log.e(TAG, "Firestore accepted update failed: ${e.message}", e)
                    }

                CallNotificationHelper.cancelIncomingCallNotification(context, callId)

                // Route accept through MainActivity so Flutter receives ACTION_ACCEPT_CALL
                // and opens the call screen in auto-answer mode.
                val launchIntent = Intent(context, MainActivity::class.java).apply {
                    action = ACTION_ACCEPT_CALL
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra(IncomingCallActivity.EXTRA_CALL_ID, callId)
                    putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, callerName)
                    putExtra(IncomingCallActivity.EXTRA_IS_VIDEO, isVideo)
                }

                try {
                    Log.d(TAG, "Launching MainActivity for accepted callId=$callId")
                    context.startActivity(launchIntent)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to launch MainActivity on accept: ${e.message}", e)
                }
            }

            ACTION_DECLINE_CALL -> {
                Log.d(TAG, "Decline clicked for callId=$callId")

                FirebaseFirestore.getInstance()
                    .collection("calls")
                    .document(callId)
                    .update("status", "declined")
                    .addOnSuccessListener {
                        Log.d(TAG, "Firestore declined update success for callId=$callId")
                    }
                    .addOnFailureListener { e ->
                        Log.e(TAG, "Firestore declined update failed: ${e.message}", e)
                    }

                CallNotificationHelper.cancelIncomingCallNotification(context, callId)
            }

            else -> {
                Log.d(TAG, "Unknown action received: $receivedAction")
            }
        }
    }
}
