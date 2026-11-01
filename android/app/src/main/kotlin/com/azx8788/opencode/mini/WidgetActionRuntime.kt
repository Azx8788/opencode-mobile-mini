package com.azx8788.opencode.mini

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/** Headless, plugin-registered engine for exactly one user-tapped widget action. */
internal class WidgetActionRuntime(
    private val context: Context,
    private val payload: Map<String, Any?>,
    private val snapshot: JSONObject,
    private val deadlineEpochMs: Long,
    private val operation: String = "execute",
    private val complete: (Map<*, *>?) -> Unit,
) {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var destroyed = false
    private var executed = false

    fun start() {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationCompleteAsync(context, null, Handler(Looper.getMainLooper())) {
            if (destroyed) return@ensureInitializationCompleteAsync
            try {
                // FlutterEngine automatically registers generated plugins. No activity
                // is attached: credentials remain in Dart's ProfileStore/Keystore path.
                val created = FlutterEngine(context)
                engine = created
                channel = MethodChannel(created.dartExecutor.binaryMessenger, "oc/widget_action").also { bridge ->
                    bridge.setMethodCallHandler { call, result ->
                        if (call.method != "ready") {
                            result.notImplemented()
                        } else {
                            result.success(null)
                            if (!executed && !destroyed) {
                                executed = true
                                bridge.invokeMethod(operation, mapOf(
                                    "action" to payload,
                                    "snapshot" to jsonMap(snapshot),
                                    "deadlineEpochMs" to deadlineEpochMs,
                                ), object : MethodChannel.Result {
                                    override fun success(result: Any?) {
                                        if (!destroyed) complete(result as? Map<*, *>)
                                    }
                                    override fun error(code: String, message: String?, details: Any?) {
                                        if (!destroyed) complete(null)
                                    }
                                    override fun notImplemented() { if (!destroyed) complete(null) }
                                })
                            }
                        }
                    }
                }
                created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "package:opencode_mobile/background/widget_action_entrypoint.dart",
                    "widgetActionMain",
                ))
            } catch (_: RuntimeException) {
                if (!destroyed) complete(null)
            }
        }
    }

    fun destroy() {
        if (destroyed) return
        destroyed = true
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
    }

    private fun jsonMap(value: JSONObject): Map<String, Any?> =
        value.keys().asSequence().associateWith { jsonValue(value.opt(it)) }
    private fun jsonValue(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> jsonMap(value)
        is JSONArray -> (0 until value.length()).map { jsonValue(value.opt(it)) }
        else -> value
    }
}
