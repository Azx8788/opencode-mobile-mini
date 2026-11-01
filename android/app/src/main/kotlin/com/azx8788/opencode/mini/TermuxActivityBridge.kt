package com.azx8788.opencode.mini

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Owns the activity-facing Termux channel and its permission request lifetime. */
internal class TermuxActivityBridge(private val activity: Activity, private val handler: Handler) {
    private val environment = TermuxActivityEnvironment(activity)
    private val permissions = TermuxActivityPermissions(activity, environment)
    private val commands = TermuxActivityCommands(activity, handler, environment)
    private val setup = TermuxActivitySetup(activity, handler, environment)

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCapabilities" -> result.success(environment.capabilities())
            "getSigningCertificateSha256" -> result.success(environment.signingCertificateSha256())
            "requestRunCommandPermission" -> permissions.requestPermission(result)
            "requestRunCommandAccess" -> permissions.requestAccess(result)
            "openTermux" -> result.success(environment.openTermux())
            "openAppSettings" -> {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:${activity.packageName}")
                    )
                )
                result.success(true)
            }
            "runInTermux" -> commands.run(call, result)
            "startSetup", "setupStatus", "cancelSetup", "completeSetupStep",
            "setupHostInstalled", "setupRun" -> setup.handle(call, result)
            "openTermuxSession" -> commands.openSession(call, result)
            else -> result.notImplemented()
        }
    }

    fun onPermissionResult(grantResults: IntArray) = permissions.onPermissionResult(grantResults)

    fun reset() = permissions.reset()

    companion object {
        const val PERMISSION_REQUEST = 4701
    }
}
