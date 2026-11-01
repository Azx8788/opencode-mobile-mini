package com.azx8788.opencode.mini

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Shared UI/headless host. Phone ownership is scoped to this bridge instance. */
internal class ScheduledPromptChannel(private val context: Context) {
    private val scheduler = ScheduledPromptScheduler(context)
    private val calls = ScheduledPromptCalls(context) { closed }
    private val executor = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    @Volatile private var closed = false

    fun register(messenger: BinaryMessenger, ready: ((MethodChannel) -> Unit)? = null) {
        val bridge = MethodChannel(messenger, "oc/scheduled_prompts")
        channel = bridge
        bridge.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    result.success(null)
                    ready?.invoke(bridge)
                }
                "consumeOpen" -> result.success(consumeOpen())
                "requestExactAlarm" -> requestExactAlarm(result)
                else -> executor.execute { runCall(call, result) }
            }
        }
    }

    private fun requestExactAlarm(result: MethodChannel.Result) {
        try {
            if (context is Activity && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !scheduler.exactAllowed()) {
                val settings = Uri.parse("package:${context.packageName}")
                context.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, settings))
            }
            result.success(null)
        } catch (_: Exception) {
            result.error("unavailable", "Exact timing settings are unavailable.", null)
        }
    }

    private fun runCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            check(!closed)
            val value = calls.handle(call)
            handler.post {
                if (value === ScheduledPromptCalls.UNKNOWN) result.notImplemented() else result.success(value)
            }
        } catch (_: Exception) {
            handler.post { result.error("unavailable", "Scheduled prompts are unavailable.", null) }
        }
    }

    fun notifyOpen() {
        if (!closed) channel?.invokeMethod("openAvailable", null)
    }

    fun close() {
        if (closed) return
        closed = true
        channel?.setMethodCallHandler(null)
        channel = null
        executor.execute { calls.releaseAll() }
        executor.shutdown()
    }

    companion object {
        const val OPEN_PROFILE = "scheduledProfileId"
        const val OPEN_SCHEDULE = "scheduledPromptId"
        const val OPEN_SESSION = "scheduledSessionId"
        private var pendingOpen: Map<String, String>? = null
        @Synchronized fun captureOpen(intent: Intent?) {
            val profile = intent?.getStringExtra(OPEN_PROFILE)?.takeIf { ScheduledPromptPolicy.validId(it) }
                ?: return
            pendingOpen = mapOf(
                "profileId" to profile, "scheduleId" to intent.getStringExtra(OPEN_SCHEDULE).orEmpty(),
                "sessionId" to intent.getStringExtra(OPEN_SESSION).orEmpty(),
            )
            intent.removeExtra(OPEN_PROFILE)
            intent.removeExtra(OPEN_SCHEDULE)
            intent.removeExtra(OPEN_SESSION)
        }
        @Synchronized private fun consumeOpen(): Map<String, String> = pendingOpen.orEmpty().also { pendingOpen = null }
    }
}
