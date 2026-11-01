package com.azx8788.opencode.mini

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.IBinder
import java.util.concurrent.ConcurrentHashMap

object TermuxCommandRegistry {
    private val callbacks = ConcurrentHashMap<Int, (Bundle?) -> Unit>()

    fun register(executionId: Int, callback: (Bundle?) -> Unit) {
        callbacks[executionId] = callback
    }

    fun complete(executionId: Int, result: Bundle?) {
        callbacks.remove(executionId)?.invoke(result)
    }

    fun remove(executionId: Int): Boolean = callbacks.remove(executionId) != null
}

/** UUID identities cannot collide with a callback from an earlier app process. */
object TermuxSetupCommandRegistry {
    private val callbacks = ConcurrentHashMap<String, (Bundle?) -> Unit>()
    fun register(token: String, callback: (Bundle?) -> Unit) { callbacks[token] = callback }
    fun complete(token: String, result: Bundle?) { callbacks.remove(token)?.invoke(result) }
    fun remove(token: String) { callbacks.remove(token) }
}

class TermuxResultService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val executionId = intent?.getIntExtra(EXTRA_EXECUTION_ID, -1) ?: -1
        val result = intent?.getBundleExtra(EXTRA_RESULT_BUNDLE)
        val setupToken = intent?.getStringExtra("oc.setupToken")
        if (setupToken != null) {
            TermuxSetupCommandRegistry.complete(setupToken, result)
        } else if (executionId >= 0) TermuxCommandRegistry.complete(executionId, result)
        stopSelf(startId)
        return START_NOT_STICKY
    }

    companion object {
        private const val EXTRA_EXECUTION_ID = "oc.executionId"
        private const val EXTRA_RESULT_BUNDLE = "result"
    }
}
