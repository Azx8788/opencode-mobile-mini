package com.azx8788.opencode.mini

import android.app.Activity
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * A Termux-owned setup process, independent of the Flutter/Android process.
 * Only redacted component metadata is stored in app storage. Scripts exist in
 * the RUN_COMMAND payload and the shell's memory, never a persisted script or
 * log. Termux stores fixed state words and numeric progress, not raw output.
 * Callback loss is not process death: status reconciles the actual shell lock.
 */
class TermuxSetupRunner private constructor(private val context: Context) {
    private val file = File(context.filesDir, "termux-setup-v2.json")
    private val lock = Any()

    fun start(jobId: String, specs: List<Map<String, Any?>>, params: Map<String, Any?>) = synchronized(lock) {
        require(ID.matches(jobId) && specs.isNotEmpty()) { "Invalid setup job" }
        val previous = read()
        if (previous != null && previous.optString("state") == "running") {
            reconcile(previous)
            if (previous.optString("state") == "running") {
                if (previous.optString("jobId") == jobId) return@synchronized
                error("A Termux setup job is still running")
            }
        }
        val components = specs.map { spec ->
            val id = spec["id"] as? String ?: error("Invalid setup component")
            require(COMPONENT.matches(id)) { "Invalid setup component" }
            require(spec["native"] != true || id == "linux") { "Unknown native component" }
            SetupComponentStatus(
                id = id,
                state = if (spec["skipped"] == true) "skipped" else "pending",
                weight = (spec["weight"] as? Number)?.toDouble()?.takeIf { it.isFinite() && it > 0 } ?: 1.0,
                version = spec["version"] as? String,
                data = (spec["data"] as? Map<*, *>)?.entries?.mapNotNull {
                    val key = it.key as? String
                    val value = it.value as? String
                    if (key in setOf("runtime", "openCodeChanged") && value != null) key!! to value else null
                }?.toMap().orEmpty(),
            )
        }
        require(components.map { it.id }.distinct().size == components.size) { "Duplicate setup component" }
        command("command -v flock >/dev/null && command -v setsid >/dev/null", 15_000)
        require(previous?.optString("jobId") != jobId) { "A finished setup job needs a new id" }
        val state = SetupJobState(jobId, "running", components, startedAt = System.currentTimeMillis()).toJson()
        state.put("host", "termux")
        state.put("params", JSONObject(params))
        // Persist before dispatch. A timeout after dispatch keeps running truth
        // unknown until a later probe, instead of permitting a duplicate job.
        write(state)
        command(TermuxSetupShell.launch(jobId, specs), 30_000)
    }

    fun status(): String? = synchronized(lock) {
        val current = read() ?: return@synchronized null
        reconcile(current)
        current.toString()
    }

    fun cancel() = synchronized(lock) {
        val current = read() ?: return@synchronized
        command(TermuxSetupShell.cancel(current.getString("jobId")), 15_000)
        reconcile(current)
    }

    fun completeStep(jobId: String, id: String, ok: Boolean, version: String?) = synchronized(lock) {
        require(ID.matches(jobId) && COMPONENT.matches(id)) { "Invalid setup step" }
        val current = read() ?: return@synchronized
        if (current.optString("jobId") != jobId || current.optString("state") != "running") return@synchronized
        reconcile(current)
        if (current.optString("current") != id) return@synchronized
        command(TermuxSetupShell.complete(jobId, id, ok), 15_000)
        // Result versions are deliberately omitted: arbitrary command output
        // is never durable metadata. The subsequent health check reads version.
        reconcile(current)
    }

    fun installed(): Boolean {
        val result = command("proot-distro login opencode-ubuntu -- /bin/true >/dev/null 2>&1", 30_000, false)
        return result.getInt("exitCode", -1) == 0 && result.getInt("err", Activity.RESULT_CANCELED) == Activity.RESULT_OK
    }

    fun run(script: String, timeoutMs: Long): Map<String, Any?> {
        val result = command("proot-distro login opencode-ubuntu -- /bin/bash -c ${TermuxSetupShell.quote(script)}", timeoutMs, false)
        return mapOf(
            "stdout" to result.getString("stdout", ""),
            "stderr" to result.getString("stderr", ""),
            "exitCode" to result.getInt("exitCode", -1),
            "err" to result.getInt("err", Activity.RESULT_CANCELED),
            "errorMessage" to "",
        )
    }

    private fun reconcile(current: JSONObject) {
        val result = command(TermuxSetupShell.probe(current.getString("jobId")), 15_000)
        val state = SetupJobState.fromJson(current)
        for (line in result.getString("stdout", "").orEmpty().lineSequence()) {
            val parts = line.split('|')
            when (parts.firstOrNull()) {
                "state" -> parts.getOrNull(1)?.takeIf { it in STATES }?.let { state.state = it }
                "current" -> parts.getOrNull(1)?.takeIf { id -> state.components.any { it.id == id } }?.let { state.current = it }
                "component" -> {
                    val component = state.components.firstOrNull { it.id == parts.getOrNull(1) } ?: continue
                    parts.getOrNull(2)?.takeIf { it in COMPONENT_STATES }?.let { component.state = it }
                    component.percent = parts.getOrNull(3)?.toDoubleOrNull()?.takeIf { it.isFinite() && it in 0.0..100.0 }
                    component.done = parts.getOrNull(4)?.toLongOrNull()?.takeIf { it >= 0 }
                    component.total = parts.getOrNull(5)?.toLongOrNull()?.takeIf { it >= 0 }
                    if (component.state == "failed") component.error = "Component installation failed. Retry setup."
                }
            }
        }
        if (state.state == "interrupted" || state.state == "cancelled") {
            state.components.filter { it.state == "running" }.forEach { it.state = "pending" }
        }
        if (state.state == "done") state.current = null
        if (state.state == "failed") state.error = "Termux setup failed. Retry setup."
        state.updatedAt = System.currentTimeMillis()
        val updated = state.toJson().put("host", "termux").put("params", current.optJSONObject("params") ?: JSONObject())
        for (key in updated.keys()) current.put(key, updated.get(key))
        write(current)
    }

    private fun read(): JSONObject? = if (file.isFile) JSONObject(file.readText()) else null

    private fun write(json: JSONObject) {
        val temporary = File(file.parentFile, "${file.name}.tmp")
        temporary.outputStream().use { stream ->
            stream.write(json.toString().toByteArray(Charsets.UTF_8))
            stream.fd.sync()
        }
        check(temporary.renameTo(file)) { "Could not persist Termux setup" }
    }

    private fun command(script: String, timeoutMs: Long, requireSuccess: Boolean = true): Bundle {
        val id = nextId.getAndIncrement()
        val token = UUID.randomUUID().toString()
        val latch = CountDownLatch(1)
        var response: Bundle? = null
        TermuxSetupCommandRegistry.register(token) { response = it; latch.countDown() }
        val callback = PendingIntent.getService(context, id,
            Intent(context, TermuxResultService::class.java).apply {
                data = Uri.parse("opencode://termux-setup/$token")
                putExtra("oc.setupToken", token)
            }, PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_MUTABLE)
        try {
            context.startService(Intent("com.termux.RUN_COMMAND").apply {
                component = ComponentName("com.termux", "com.termux.app.RunCommandService")
                putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
                putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-s"))
                putExtra("com.termux.RUN_COMMAND_STDIN", script)
                putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home")
                putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
                putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", callback)
                putExtra("com.termux.RUN_COMMAND_COMMAND_LABEL", "OpenCode setup")
            })
            check(latch.await(timeoutMs.coerceIn(1000, 120000), TimeUnit.MILLISECONDS)) {
                "Termux did not answer. Setup may still be running; reconnect to check."
            }
            val result = response ?: error("Termux returned no result")
            check(result.getInt("err", Activity.RESULT_CANCELED) == Activity.RESULT_OK) { "Termux rejected the setup command" }
            if (requireSuccess) check(result.getInt("exitCode", -1) == 0) { "Termux setup command failed" }
            return result
        } finally {
            TermuxSetupCommandRegistry.remove(token)
            callback.cancel()
        }
    }

    companion object {
        private val ID = Regex("[A-Za-z0-9_-]{1,96}")
        private val COMPONENT = Regex("[a-z][a-z0-9_-]{0,63}")
        private val STATES = setOf("running", "done", "failed", "cancelled", "interrupted")
        private val COMPONENT_STATES = setOf("pending", "running", "done", "failed", "skipped")
        private val nextId = AtomicInteger(1_000_000)
        @Volatile private var instance: TermuxSetupRunner? = null
        fun get(context: Context): TermuxSetupRunner = instance ?: synchronized(this) {
            instance ?: TermuxSetupRunner(context.applicationContext).also { instance = it }
        }
    }
}
