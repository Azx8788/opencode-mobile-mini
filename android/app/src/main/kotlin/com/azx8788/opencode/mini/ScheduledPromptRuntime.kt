package com.azx8788.opencode.mini

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** One engine for one occurrence. No Activity or permanent background preference. */
internal class ScheduledPromptRuntime(
    private val context: Context,
    private val arguments: Map<String, Any?>,
    private val complete: (Map<*, *>?) -> Unit,
) {
    private var engine: FlutterEngine? = null
    private var bridge: ScheduledPromptChannel? = null
    private var destroyed = false
    private var executed = false
    fun start() {
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationCompleteAsync(context, null, Handler(Looper.getMainLooper())) {
                if (destroyed) return@ensureInitializationCompleteAsync
                try {
                    val created = FlutterEngine(context)
                    engine = created
                    bridge = ScheduledPromptChannel(context).also { host ->
                        host.register(created.dartExecutor.binaryMessenger) { channel ->
                            if (!executed && !destroyed) {
                                executed = true
                                channel.invokeMethod("execute", arguments, object : MethodChannel.Result {
                                    override fun success(result: Any?) {
                                        if (!destroyed) complete(result as? Map<*, *>)
                                    }
                                    override fun error(code: String, message: String?, details: Any?) {
                                        if (!destroyed) complete(null)
                                    }
                                    override fun notImplemented() {
                                        if (!destroyed) complete(null)
                                    }
                                })
                            }
                        }
                    }
                    created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(
                        loader.findAppBundlePath(),
                        "package:opencode_mobile/scheduling/entrypoint.dart",
                        "scheduledPromptMain",
                    ))
                } catch (_: RuntimeException) { if (!destroyed) complete(null) }
            }
        } catch (_: RuntimeException) { if (!destroyed) complete(null) }
    }
    fun destroy() {
        if (destroyed) return
        destroyed = true
        bridge?.close(); bridge = null
        engine?.destroy(); engine = null
    }
}
