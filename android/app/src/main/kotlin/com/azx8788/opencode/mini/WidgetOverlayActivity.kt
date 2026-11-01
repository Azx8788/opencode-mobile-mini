package com.azx8788.opencode.mini

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Isolated transparent route host; never initializes MainActivity's connection handlers. */
class WidgetOverlayActivity : FlutterActivity() {
    private var bridge: MethodChannel? = null
    private var mode = "configure"
    private lateinit var session: WidgetOverlaySession

    override fun getDartEntrypointFunctionName(): String = "widgetOverlayMain"
    override fun getInitialRoute(): String = "/widgets/$mode"
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        mode = intent.getStringExtra(WidgetV2Bridge.EXTRA_MODE) ?: "configure"
        val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        val launch = WidgetV2Bridge.parsePayload(intent.getStringExtra(WidgetV2Bridge.EXTRA_PAYLOAD)).orEmpty()
        session = WidgetOverlaySession(this, launch, mode, widgetId, savedInstanceState)
        super.onCreate(savedInstanceState)
        setResult(Activity.RESULT_CANCELED)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oc/widgets").also { channel ->
            channel.setMethodCallHandler(session::handle)
        }
    }

    @Deprecated("Android activity result compatibility API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        session.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        session.destroy()
        super.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        session.save(outState)
        super.onSaveInstanceState(outState)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.setMethodCallHandler(null)
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        const val READY_META = "com.azx8788.opencode.mini.WIDGET_OVERLAY_READY"
    }
}
