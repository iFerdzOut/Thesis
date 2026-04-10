package com.example.flutter_application_1

import android.util.Log
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class SmishingFirebaseMessagingService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "SmishingFCM"
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)

        val data = message.data
        Log.d(TAG, "FCM from=${message.from}")
        Log.d(TAG, "FCM messageId=${message.messageId}")
        Log.d(TAG, "FCM data payload=$data")

        if (IncomingCallPushHandler.handleFromRemoteData(this, data, TAG)) {
            return
        }

        val shouldHandleChatNatively =
            (IncomingCallPushHandler.isDeviceLocked(this) ||
                !IncomingCallPushHandler.isAppForegroundOrVisible(this)) &&
                ChatPushHandler.handleFromRemoteData(this, data, TAG)

        if (!shouldHandleChatNatively) {
            Log.d(TAG, "Ignoring push because it is not a call/chat payload")
        }
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)

        val uid = FirebaseAuth.getInstance().currentUser?.uid ?: run {
            Log.d(TAG, "onNewToken skipped because no logged-in user")
            return
        }

        FirebaseFirestore.getInstance()
            .collection("users")
            .document(uid)
            .set(mapOf("fcmToken" to token), SetOptions.merge())
            .addOnSuccessListener {
                Log.d(TAG, "FCM token updated for uid=$uid")
            }
            .addOnFailureListener { e ->
                Log.e(TAG, "Failed to update FCM token: ${e.message}", e)
            }
    }
}
