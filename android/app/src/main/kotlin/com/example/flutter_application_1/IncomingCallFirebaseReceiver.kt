package com.example.flutter_application_1

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingReceiver

class IncomingCallFirebaseReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "IncomingCallReceiver"
    }

    private val flutterReceiver = FlutterFirebaseMessagingReceiver()

    override fun onReceive(context: Context, intent: Intent) {
        val extras = intent.extras
        val appForegroundOrVisible = IncomingCallPushHandler.isAppForegroundOrVisible(context)
        val deviceLocked = IncomingCallPushHandler.isDeviceLocked(context)
        val shouldHandleCallNatively =
            IncomingCallPushHandler.looksLikeCallPush(extras) &&
                (
                    deviceLocked || !appForegroundOrVisible
                    )

        if (shouldHandleCallNatively) {
            val handled = IncomingCallPushHandler.handleFromIntentExtras(
                context = context,
                extras = extras,
                source = "IncomingCallFirebaseReceiver"
            )

            if (handled) {
                Log.d(TAG, "Call push handled natively before FlutterFire fallback")
                if (isOrderedBroadcast) {
                    abortBroadcast()
                }
                return
            }
        }

        val shouldHandleChatNatively =
            ChatPushHandler.looksLikeChatPush(extras) &&
                (deviceLocked || !appForegroundOrVisible)

        if (shouldHandleChatNatively) {
            val handled = ChatPushHandler.handleFromIntentExtras(
                context = context,
                extras = extras,
                source = "IncomingCallFirebaseReceiver"
            )

            if (handled) {
                Log.d(TAG, "Chat push handled natively before FlutterFire fallback")
                if (isOrderedBroadcast) {
                    abortBroadcast()
                }
                return
            }
        }

        flutterReceiver.onReceive(context, intent)
    }
}
