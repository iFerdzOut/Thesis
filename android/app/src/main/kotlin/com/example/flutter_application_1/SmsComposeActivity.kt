package com.example.flutter_application_1

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle

class SmsComposeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val sourceIntent = intent
        val phone = extractPhone(sourceIntent)
        val body =
            sourceIntent.getStringExtra("sms_body")
                ?: sourceIntent.getStringExtra(Intent.EXTRA_TEXT)
                ?: sourceIntent.getStringExtra("body")
                ?: ""

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            action = SmsIntentActions.ACTION_OPEN_SMS_COMPOSE
            flags =
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(SmsIntentActions.EXTRA_PHONE, phone)
            putExtra(SmsIntentActions.EXTRA_BODY, body)
            putExtra(SmsIntentActions.EXTRA_SOURCE_ACTION, sourceIntent.action ?: "")
        }

        startActivity(launchIntent)
        finish()
    }

    private fun extractPhone(intent: Intent): String {
        intent.getStringExtra("address")?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        val data = intent.data
        if (data != null) {
            val schemeSpecific = data.schemeSpecificPart.orEmpty()
            if (schemeSpecific.isNotBlank()) {
                return schemeSpecific.substringBefore('?')
            }
        }
        return Uri.decode(intent.dataString ?: "").substringAfter(':', "")
    }
}
