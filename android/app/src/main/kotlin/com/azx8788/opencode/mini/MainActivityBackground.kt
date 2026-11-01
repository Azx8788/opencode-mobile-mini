package com.azx8788.opencode.mini

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

internal class MainActivityBackground(private val activity: Activity, private val handler: Handler) {
    private var backgroundPermissionResult: MethodChannel.Result? = null
    private var backgroundStartResult: MethodChannel.Result? = null
    private var backgroundStartCallback: Runnable? = null

    fun onPermissionResult(grantResults: IntArray) {
        val result = backgroundPermissionResult ?: return
        backgroundPermissionResult = null
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        if (granted) {
            startBackgroundConnection(result)
        } else {
            result.error(
                "notification_denied",
                "Notification access is required so Android can show the live connection.",
                null
            )
        }
    }

    fun enableBackgroundConnection(result: MethodChannel.Result) {
        if (backgroundStartResult != null) {
            result.error("permission_in_progress", "A live connection start is already pending.", null)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (backgroundPermissionResult != null) {
                result.error("permission_in_progress", "A notification permission request is open.", null)
            } else {
                backgroundPermissionResult = result
                activity.requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    BACKGROUND_NOTIFICATION_PERMISSION_REQUEST
                )
            }
        } else {
            startBackgroundConnection(result)
        }
    }

    private fun startBackgroundConnection(result: MethodChannel.Result) {
        backgroundStartResult = result
        try {
            BackgroundConnectionService.start(activity)
            awaitBackgroundStart(result, android.os.SystemClock.uptimeMillis() + BACKGROUND_START_ACK_MS)
        } catch (_: Exception) {
            backgroundStartResult = null
            result.error(
                "foreground_service_failed",
                "Android could not start the live connection.",
                null
            )
        }
    }

    /** Bounded acknowledgment only: never retries a service start. */
    private fun awaitBackgroundStart(result: MethodChannel.Result, deadline: Long) {
        if (backgroundStartResult !== result) return
        val failure = BackgroundConnectionService.lastStartFailure
        if (BackgroundConnectionService.active || failure != null ||
            android.os.SystemClock.uptimeMillis() >= deadline
        ) {
            backgroundStartResult = null
            backgroundStartCallback = null
            val status = backgroundStatus()
            result.success(
                if (BackgroundConnectionService.active) status
                else status + ("startFailure" to (failure ?: "ackTimeout"))
            )
            return
        }
        val callback = Runnable { awaitBackgroundStart(result, deadline) }
        backgroundStartCallback = callback
        handler.postDelayed(callback, BACKGROUND_START_POLL_MS)
    }

    fun cancelBackgroundRequests() {
        backgroundStartCallback?.let { handler.removeCallbacks(it) }
        backgroundStartCallback = null
        val starting = backgroundStartResult
        val permission = backgroundPermissionResult
        backgroundStartResult = null
        backgroundPermissionResult = null
        starting?.error("foreground_service_failed", "The live connection start was interrupted.", null)
        permission?.error("foreground_service_failed", "The live connection start was interrupted.", null)
    }

    fun backgroundPauseStatus(): Map<String, Any?> = runCatching {
        BackgroundPauseStore(activity).status(BackgroundConnectionService.active)
    }.getOrElse { mapOf("supported" to false) }

    fun backgroundStatus(enabled: Boolean = BackgroundConnectionService.active): Map<String, Any> {
        val notifications = activity.getSystemService(NotificationManager::class.java)
        val notificationGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            notifications.areNotificationsEnabled()
        val power = activity.getSystemService(PowerManager::class.java)
        return mapOf(
            "enabled" to enabled,
            "active" to BackgroundConnectionService.active,
            "backgroundPause" to backgroundPauseStatus(),
            "notificationGranted" to notificationGranted,
            "batteryOptimizationIgnored" to power.isIgnoringBatteryOptimizations(activity.packageName)
        )
    }

    fun requestBatteryOptimizationExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val power = activity.getSystemService(PowerManager::class.java)
        if (power.isIgnoringBatteryOptimizations(activity.packageName)) return
        activity.startActivity(
            Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${activity.packageName}")
            )
        )
    }

    companion object {
        const val PERMISSION_REQUEST = 4703
        private const val BACKGROUND_NOTIFICATION_PERMISSION_REQUEST = PERMISSION_REQUEST
        // A busy phone (in-app Linux, agents) can take more than two seconds
        // to run the service's start; Android itself allows it longer.
        private const val BACKGROUND_START_ACK_MS = 5000L
        private const val BACKGROUND_START_POLL_MS = 50L
    }
}
