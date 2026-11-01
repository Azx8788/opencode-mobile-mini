package com.azx8788.opencode.mini

import android.app.Activity
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.net.Uri
import android.os.Handler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

internal class TermuxActivityCommands(
    private val activity: Activity,
    private val handler: Handler,
    private val environment: TermuxActivityEnvironment
) {
    fun run(call: MethodCall, result: MethodChannel.Result) {
        val script = call.argument<String>("script").orEmpty()
        when {
            script.isBlank() -> result.error("invalid_script", "The Termux command is empty.", null)
            canDispatch(result) -> dispatchRun(call, script, result)
        }
    }

    private fun canDispatch(result: MethodChannel.Result): Boolean = when {
        !environment.hasPermission() -> {
            result.error("permission_denied", "OpenCode does not have Termux's RUN_COMMAND permission.", null)
            false
        }
        !environment.isServiceAvailable() -> {
            result.error("service_unavailable", "This Termux build does not expose RunCommandService.", null)
            false
        }
        else -> true
    }

    private fun dispatchRun(call: MethodCall, script: String, result: MethodChannel.Result) {
        val executionId = nextExecutionId.getAndIncrement()
        val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: DEFAULT_TIMEOUT_MS)
            .coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val timeout = Runnable {
            if (TermuxCommandRegistry.remove(executionId)) {
                result.error(
                    "command_timeout",
                    "Termux did not return a command result within ${timeoutMs / MILLIS_PER_SECOND} seconds.",
                    null
                )
            }
        }
        TermuxCommandRegistry.register(executionId) { bundle ->
            handler.removeCallbacks(timeout)
            handler.post { deliverResult(bundle, result) }
        }
        handler.postDelayed(timeout, timeoutMs)
        val callback = callback(executionId)
        val command = commandIntent().apply {
            putExtra(EXTRA_ARGUMENTS, arrayOf("-s"))
            putExtra(EXTRA_STDIN, script)
            putExtra(EXTRA_WORKDIR, call.argument<String>("workdir") ?: TERMUX_HOME)
            putExtra(EXTRA_BACKGROUND, call.argument<Boolean>("background") ?: true)
            putExtra(EXTRA_PENDING_INTENT, callback)
        }
        runCatching { activity.startService(command) }.onFailure { error ->
            if (error !is Exception) throw error
            handler.removeCallbacks(timeout)
            TermuxCommandRegistry.remove(executionId)
            result.error("dispatch_failed", error.message ?: "Termux rejected the command.", null)
        }
    }

    private fun deliverResult(bundle: Bundle?, result: MethodChannel.Result) {
        if (bundle == null) {
            result.error("missing_result", "Termux returned no result bundle.", null)
        } else {
            result.success(
                mapOf(
                    "stdout" to bundle.getString("stdout", ""),
                    "stderr" to bundle.getString("stderr", ""),
                    "exitCode" to bundle.getInt("exitCode", -1),
                    "err" to bundle.getInt("err", Activity.RESULT_CANCELED),
                    "errorMessage" to bundle.getString("errmsg", "")
                )
            )
        }
    }

    private fun callback(executionId: Int): PendingIntent {
        val callbackIntent = Intent(activity, TermuxResultService::class.java).apply {
            data = Uri.parse("opencode://termux-result/$executionId/${System.nanoTime()}")
            putExtra(EXTRA_EXECUTION_ID, executionId)
        }
        return PendingIntent.getService(
            activity,
            executionId,
            callbackIntent,
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_MUTABLE
        )
    }

    /**
     * Opens an interactive terminal with `bash -c`: Termux feeds stdin only to background commands.
     * No result is awaited because the session lives as long as the person needs it.
     */
    fun openSession(call: MethodCall, result: MethodChannel.Result) {
        val script = call.argument<String>("command").orEmpty()
        when {
            script.isBlank() || script.length > MAX_SESSION_COMMAND_LENGTH ->
                result.error("invalid_script", "The Termux command is empty or too long.", null)
            canDispatch(result) -> dispatchSession(script, result)
        }
    }

    private fun dispatchSession(script: String, result: MethodChannel.Result) {
        val command = commandIntent().apply {
            putExtra(EXTRA_ARGUMENTS, arrayOf("-c", script))
            putExtra(EXTRA_WORKDIR, TERMUX_HOME)
            putExtra(EXTRA_BACKGROUND, false)
            putExtra(EXTRA_SESSION_ACTION, "0")
        }
        val dispatched = runCatching { activity.startService(command) }.onFailure { error ->
            if (error !is Exception) throw error
            result.error("dispatch_failed", error.message ?: "Termux rejected the command.", null)
        }.isSuccess
        if (dispatched) result.success(environment.openTermux())
    }

    private fun commandIntent() = Intent(ACTION_RUN_COMMAND).apply {
        component = ComponentName(TermuxActivityEnvironment.PACKAGE, TermuxActivityEnvironment.SERVICE)
        putExtra(EXTRA_COMMAND_PATH, TERMUX_BASH)
        putExtra(EXTRA_COMMAND_LABEL, "OpenCode mobile")
    }

    companion object {
        private const val DEFAULT_TIMEOUT_MS = 30_000L
        private const val MIN_TIMEOUT_MS = 1_000L
        private const val MAX_TIMEOUT_MS = 120_000L
        private const val MILLIS_PER_SECOND = 1_000L
        private const val MAX_SESSION_COMMAND_LENGTH = 512
        private const val TERMUX_HOME = "/data/data/com.termux/files/home"
        private const val TERMUX_BASH = "/data/data/com.termux/files/usr/bin/bash"
        private const val ACTION_RUN_COMMAND = "com.termux.RUN_COMMAND"
        private const val EXTRA_COMMAND_PATH = "com.termux.RUN_COMMAND_PATH"
        private const val EXTRA_ARGUMENTS = "com.termux.RUN_COMMAND_ARGUMENTS"
        private const val EXTRA_STDIN = "com.termux.RUN_COMMAND_STDIN"
        private const val EXTRA_WORKDIR = "com.termux.RUN_COMMAND_WORKDIR"
        private const val EXTRA_BACKGROUND = "com.termux.RUN_COMMAND_BACKGROUND"
        private const val EXTRA_SESSION_ACTION = "com.termux.RUN_COMMAND_SESSION_ACTION"
        private const val EXTRA_PENDING_INTENT = "com.termux.RUN_COMMAND_PENDING_INTENT"
        private const val EXTRA_COMMAND_LABEL = "com.termux.RUN_COMMAND_COMMAND_LABEL"
        private const val EXTRA_EXECUTION_ID = "oc.executionId"
        private val nextExecutionId = AtomicInteger(1)
    }
}
