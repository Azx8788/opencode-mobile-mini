package com.azx8788.opencode.mini

import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class LaunchLinkChannel {
    private var pending: String? = null
    private var channel: MethodChannel? = null
    private var dartReady = false

    fun configure(messenger: BinaryMessenger) {
        dartReady = false
        channel = MethodChannel(messenger, "oc/link").also { linkChannel ->
            linkChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeSessionLink" -> {
                        // Dart has installed its inbound handler before acknowledging readiness.
                        dartReady = true
                        val link = pending
                        pending = null
                        result.success(link)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun reset() {
        channel = null
        dartReady = false
    }

    fun onNewIntent(intent: Intent) {
        if (capture(intent)) {
            val currentChannel = channel
            val link = pending
            if (dartReady && currentChannel != null && link != null) {
                pending = null
                currentChannel.invokeMethod("linked", link)
            }
        }
    }

    /** Only accepted handoff routes cross to Dart, which validates their identifiers. */
    fun capture(intent: Intent?): Boolean {
        val data = intent?.data
        if (intent?.action != Intent.ACTION_VIEW || data == null || !isHandoffRoute(data)) return false
        val text = data.toString()
        // Consume even a rejected handoff link so configuration changes cannot replay it.
        intent.action = Intent.ACTION_MAIN
        intent.data = null
        val accepted = SessionLinkIngress.accepts(text)
        if (accepted) pending = text
        return accepted
    }

    private fun isHandoffRoute(data: Uri): Boolean =
        data.scheme.equals("opencode-mobile", ignoreCase = true) &&
            (data.host.equals("session", ignoreCase = true) || data.host.equals("team", ignoreCase = true))
}
