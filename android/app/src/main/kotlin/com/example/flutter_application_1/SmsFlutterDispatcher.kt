package com.example.flutter_application_1

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object SmsFlutterDispatcher {
    private const val TAG = "SmsFlutterDispatcher"
    private const val CHANNEL = "sms_channel"
    private val mainHandler = Handler(Looper.getMainLooper())

    fun dispatch(method: String, arguments: Any?): Boolean {
        val engine = FlutterEngineCache.getInstance().get("main_engine") ?: return false
        mainHandler.post {
            try {
                MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                    .invokeMethod(method, arguments)
            } catch (error: Exception) {
                Log.e(TAG, "Failed to dispatch $method: ${error.message}", error)
            }
        }
        return true
    }

    fun dispatchForResult(
        method: String,
        arguments: Any?,
        timeoutMs: Long = 2500L
    ): Any? {
        val engine = FlutterEngineCache.getInstance().get("main_engine") ?: return null
        val latch = CountDownLatch(1)
        var response: Any? = null

        mainHandler.post {
            try {
                MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                    .invokeMethod(method, arguments, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            response = result
                            latch.countDown()
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?
                        ) {
                            Log.w(
                                TAG,
                                "dispatchForResult($method) error: $errorCode $errorMessage"
                            )
                            latch.countDown()
                        }

                        override fun notImplemented() {
                            Log.w(TAG, "dispatchForResult($method) not implemented")
                            latch.countDown()
                        }
                    })
            } catch (error: Exception) {
                Log.e(TAG, "Failed to dispatch $method for result: ${error.message}", error)
                latch.countDown()
            }
        }

        return if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
            response
        } else {
            Log.w(TAG, "dispatchForResult($method) timed out after ${timeoutMs}ms")
            null
        }
    }

    fun dispatchOrQueue(
        context: Context,
        method: String,
        eventType: String,
        payload: Map<String, Any?>
    ) {
        if (!dispatch(method, payload)) {
            SmsEventStore.queueEvent(
                context = context,
                eventType = eventType,
                payload = payload
            )
        }
    }
}
