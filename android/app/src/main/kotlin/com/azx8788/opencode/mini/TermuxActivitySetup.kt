package com.azx8788.opencode.mini

import android.app.Activity
import android.os.Handler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class TermuxActivitySetup(
    private val activity: Activity,
    private val handler: Handler,
    private val environment: TermuxActivityEnvironment
) {
    /** Setup retains the same RUN_COMMAND permission and service boundary as commands. */
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when {
            !environment.hasPermission() ->
                result.error("permission_denied", "Termux RUN_COMMAND permission is required.", null)
            !environment.isServiceAvailable() ->
                result.error("service_unavailable", "Termux RunCommandService is unavailable.", null)
            else -> Thread({ run(call, result) }, "oc-termux-setup").start()
        }
    }

    private fun run(call: MethodCall, result: MethodChannel.Result) {
        try {
            val answer = execute(TermuxSetupRunner.get(activity.applicationContext), call)
            handler.post { result.success(answer) }
        } catch (_: Exception) {
            // Never expose raw exception, command or provider output in diagnostic copy.
            handler.post {
                result.error(
                    "termux_setup",
                    "Termux setup could not be confirmed. Check Termux and retry status.",
                    null
                )
            }
        }
    }

    private fun execute(runner: TermuxSetupRunner, call: MethodCall): Any? = when (call.method) {
        "startSetup" -> {
            runner.start(
                call.argument<String>("jobId") ?: error("A setup job needs an id"),
                call.argument<List<Map<String, Any?>>>("components").orEmpty(),
                call.argument<Map<String, Any?>>("params").orEmpty(),
            )
            null
        }
        "setupStatus" -> runner.status()
        "cancelSetup" -> {
            runner.cancel()
            null
        }
        "completeSetupStep" -> {
            runner.completeStep(
                call.argument<String>("jobId") ?: error("A step needs a job"),
                call.argument<String>("id") ?: error("A step needs an id"),
                call.argument<Boolean>("ok") == true,
                call.argument<String>("version"),
            )
            null
        }
        "setupHostInstalled" -> runner.installed()
        "setupRun" -> runner.run(
            call.argument<String>("script") ?: error("A check needs a script"),
            call.argument<Number>("timeoutMs")?.toLong() ?: SETUP_TIMEOUT_MS,
        )
        else -> null
    }

    companion object {
        private const val SETUP_TIMEOUT_MS = 120_000L
    }
}
