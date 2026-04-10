package com.example.flutter_application_1

object SmsIntentActions {
    const val ACTION_OPEN_SMS_NOTIFICATION =
        "com.example.flutter_application_1.ACTION_OPEN_SMS_NOTIFICATION"
    const val ACTION_OPEN_SMS_COMPOSE =
        "com.example.flutter_application_1.ACTION_OPEN_SMS_COMPOSE"
    const val ACTION_SMS_SENT =
        "com.example.flutter_application_1.ACTION_SMS_SENT"
    const val ACTION_SMS_DELIVERED =
        "com.example.flutter_application_1.ACTION_SMS_DELIVERED"

    const val EXTRA_NOTIFICATION_KEY = "notificationKey"
    const val EXTRA_SENDER = "sender"
    const val EXTRA_BODY = "body"
    const val EXTRA_TIMESTAMP = "timestamp"
    const val EXTRA_SIM_SLOT = "simSlot"
    const val EXTRA_SUBSCRIPTION_ID = "subscriptionId"
    const val EXTRA_PROVIDER_ID = "providerId"
    const val EXTRA_THREAD_ID = "threadId"
    const val EXTRA_ADDRESS = "address"
    const val EXTRA_PROVISIONAL_ID = "provisionalId"
    const val EXTRA_STATUS = "status"
    const val EXTRA_PHONE = "phone"
    const val EXTRA_SOURCE_ACTION = "sourceAction"
}
