package com.example.flutter_application_1

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.TextView
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration

class IncomingCallActivity : Activity() {

    companion object {
        const val EXTRA_CALL_ID = "callId"
        const val EXTRA_CALLER_NAME = "callerName"
        const val EXTRA_IS_VIDEO = "isVideo"
        const val EXTRA_FROM_NOTIFICATION = "fromNotification"

        const val ACTION_OPEN_FROM_NOTIFICATION =
            "com.example.flutter_application_1.ACTION_OPEN_FROM_NOTIFICATION"

        private const val TAG = "IncomingCallActivity"
        private const val AUTO_MISS_MS = 30_000L
    }

    private var mediaPlayer: MediaPlayer? = null
    private var callId: String = ""
    private var callerName: String = ""
    private var isVideo: Boolean = false
    private var callStatusListener: ListenerRegistration? = null

    private lateinit var tvCallerName: TextView
    private lateinit var tvCallType: TextView
    private lateinit var btnAccept: ImageButton
    private lateinit var btnDecline: ImageButton

    private val handler = Handler(Looper.getMainLooper())
    private val autoMissRunnable = Runnable {
        Log.d(TAG, "Auto-miss timeout for callId=$callId")
        markMissedAndClose()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "onCreate action=${intent?.action}")

        turnScreenOnAndShowOverLockscreen()
        setFinishOnTouchOutside(false)
        setContentView(R.layout.activity_incoming_call)

        tvCallerName = findViewById(R.id.tvCallerName)
        tvCallType = findViewById(R.id.tvCallType)
        btnAccept = findViewById(R.id.btnAccept)
        btnDecline = findViewById(R.id.btnDecline)

        readExtras(intent)
        bindUi()
        setupButtons()
        startRinging()
        listenToCallStatus()

        handler.removeCallbacks(autoMissRunnable)
        handler.postDelayed(autoMissRunnable, AUTO_MISS_MS)

        if (callId.isNotBlank()) {
            CallNotificationHelper.cancelIncomingCallNotification(this, callId)
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent action=${intent?.action}")
        setIntent(intent)

        turnScreenOnAndShowOverLockscreen()
        readExtras(intent)
        bindUi()
        setupButtons()
        startRinging()
        listenToCallStatus()
        handler.removeCallbacks(autoMissRunnable)
        handler.postDelayed(autoMissRunnable, AUTO_MISS_MS)

        if (callId.isNotBlank()) {
            CallNotificationHelper.cancelIncomingCallNotification(this, callId)
        }
    }

    private fun readExtras(intent: Intent?) {
        callId = intent?.getStringExtra(EXTRA_CALL_ID) ?: ""
        callerName = intent?.getStringExtra(EXTRA_CALLER_NAME) ?: "Unknown Caller"
        isVideo = intent?.getBooleanExtra(EXTRA_IS_VIDEO, false) ?: false

        Log.d(TAG, "readExtras callId=$callId callerName=$callerName isVideo=$isVideo")
    }

    private fun bindUi() {
        tvCallerName.text = callerName
        tvCallType.text = if (isVideo) "Incoming video call" else "Incoming voice call"
    }

    private fun setupButtons() {
        btnAccept.setOnClickListener { acceptCall() }
        btnDecline.setOnClickListener { declineCall() }
    }

    private fun turnScreenOnAndShowOverLockscreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val km = getSystemService(KeyguardManager::class.java)
            km?.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }

        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON
        )
    }

    private fun startRinging() {
        stopRinging()

        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            mediaPlayer = MediaPlayer().apply {
                setDataSource(this@IncomingCallActivity, uri)
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                isLooping = true
                prepare()
                start()
            }
            Log.d(TAG, "Ringtone started for callId=$callId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start ringtone: ${e.message}", e)
        }
    }

    private fun stopRinging() {
        try {
            mediaPlayer?.stop()
        } catch (_: Exception) {
        }

        try {
            mediaPlayer?.release()
        } catch (_: Exception) {
        }

        mediaPlayer = null
    }

    private fun listenToCallStatus() {
        if (callId.isBlank()) return

        callStatusListener?.remove()
        callStatusListener = FirebaseFirestore.getInstance()
            .collection("calls")
            .document(callId)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    Log.e(TAG, "Call status listener error: ${error.message}", error)
                    return@addSnapshotListener
                }

                val status = snapshot?.getString("status") ?: return@addSnapshotListener
                Log.d(TAG, "Call status changed to $status for callId=$callId")

                if (
                    status == "accepted" ||
                    status == "declined" ||
                    status == "ended" ||
                    status == "missed" ||
                    status == "cancelled"
                ) {
                    finishCallScreen()
                }
            }
    }

    private fun acceptCall() {
        if (callId.isBlank()) {
            finishCallScreen()
            return
        }

        Log.d(TAG, "acceptCall callId=$callId")

        stopRinging()
        handler.removeCallbacks(autoMissRunnable)
        CallNotificationHelper.cancelIncomingCallNotification(this, callId)

        FirebaseFirestore.getInstance()
            .collection("calls")
            .document(callId)
            .update("status", "accepted")

        val acceptIntent = Intent(this, MainActivity::class.java).apply {
            action = CallActionReceiver.ACTION_ACCEPT_CALL
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_CALL_ID, callId)
            putExtra(EXTRA_CALLER_NAME, callerName)
            putExtra(EXTRA_IS_VIDEO, isVideo)
        }

        startActivity(acceptIntent)
        finish()
    }

    private fun declineCall() {
        Log.d(TAG, "declineCall callId=$callId")

        if (callId.isNotBlank()) {
            FirebaseFirestore.getInstance()
                .collection("calls")
                .document(callId)
                .update("status", "declined")
        }

        finishCallScreen()
    }

    private fun markMissedAndClose() {
        if (callId.isNotBlank()) {
            FirebaseFirestore.getInstance()
                .collection("calls")
                .document(callId)
                .update("status", "missed")
        }

        finishCallScreen()
    }

    private fun finishCallScreen() {
        Log.d(TAG, "finishCallScreen callId=$callId")

        stopRinging()
        handler.removeCallbacks(autoMissRunnable)

        callStatusListener?.remove()
        callStatusListener = null

        if (callId.isNotBlank()) {
            CallNotificationHelper.cancelIncomingCallNotification(this, callId)
        }

        finish()
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy callId=$callId")
        stopRinging()
        handler.removeCallbacks(autoMissRunnable)
        callStatusListener?.remove()
        callStatusListener = null
        super.onDestroy()
    }
}
