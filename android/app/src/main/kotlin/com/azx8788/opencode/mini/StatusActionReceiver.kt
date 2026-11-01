package com.azx8788.opencode.mini

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Buttons on the status notification that need the running app: "Stop the
 * reply" goes to Dart over `oc/background` (`statusAction`), which stops the
 * chat the notification named. When no engine is alive, or Dart declines, the
 * app opens instead, so a tap is never silently lost.
 */
class StatusActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != StatusNotification.ACTION_STATUS) return
        val action = intent.getStringExtra(StatusNotification.EXTRA_STATUS_ACTION).orEmpty()
        val sessionID = intent.getStringExtra(StatusNotification.EXTRA_STATUS_SESSION).orEmpty()
        if (action.isBlank()) return
        val channel = MainActivity.backgroundChannel
        val appContext = context.applicationContext
        if (channel == null) {
            openApp(appContext)
        } else {
            dispatch(channel, appContext, action, sessionID)
        }
    }

    private fun dispatch(channel: MethodChannel, appContext: Context, action: String, sessionID: String) {
        Handler(Looper.getMainLooper()).post {
            channel.invokeMethod(
                StatusNotification.METHOD_STATUS_ACTION,
                mapOf("action" to action, "sessionID" to sessionID),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if ((result as? Map<*, *>)?.get("handled") != true) openApp(appContext)
                    }

                    override fun error(code: String, message: String?, details: Any?) = openApp(appContext)
                    override fun notImplemented() = openApp(appContext)
                },
            )
        }
    }

    private fun openApp(context: Context) {
        context.startActivity(
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
        )
    }
}
