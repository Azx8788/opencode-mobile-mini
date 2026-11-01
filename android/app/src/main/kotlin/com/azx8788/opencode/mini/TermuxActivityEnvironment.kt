package com.azx8788.opencode.mini

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import java.security.MessageDigest

internal class TermuxActivityEnvironment(private val activity: Activity) {
    fun capabilities(): Map<String, Any?> {
        val packageInfo = try {
            activity.packageManager.getPackageInfo(PACKAGE, 0)
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
        return mapOf(
            "installed" to (packageInfo != null),
            "version" to packageInfo?.versionName,
            "serviceAvailable" to isServiceAvailable(),
            "protocolSupported" to supportsProtocol(packageInfo?.versionName),
            "permissionGranted" to hasPermission()
        )
    }

    @Suppress("DEPRECATION")
    fun signingCertificateSha256(): String? {
        val info = activity.packageManager.getPackageInfo(
            activity.packageName,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                PackageManager.GET_SIGNATURES
            }
        )
        val signature = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners?.singleOrNull()
        } else {
            info.signatures?.singleOrNull()
        } ?: return null
        return MessageDigest.getInstance("SHA-256")
            .digest(signature.toByteArray())
            .joinToString("") { byte -> "%02X".format(byte) }
    }

    fun openTermux(): Boolean {
        val intent = activity.packageManager.getLaunchIntentForPackage(PACKAGE) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(intent)
        return true
    }

    fun hasPermission(): Boolean =
        activity.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED

    fun isServiceAvailable(): Boolean = try {
        activity.packageManager.getServiceInfo(ComponentName(PACKAGE, SERVICE), 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private fun supportsProtocol(versionName: String?): Boolean {
        val numbers = Regex("\\d+").findAll(versionName.orEmpty())
            .map { it.value.toIntOrNull() ?: 0 }
            .take(VERSION_COMPONENT_COUNT)
            .toList()
        if (numbers.size < VERSION_COMPONENT_COUNT) return false
        return numbers[0] > 0 || numbers[1] >= MIN_PROTOCOL_MINOR_VERSION
    }

    fun isInstalled(): Boolean = try {
        activity.packageManager.getPackageInfo(PACKAGE, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    companion object {
        const val PACKAGE = "com.termux"
        const val PERMISSION = "com.termux.permission.RUN_COMMAND"
        const val SERVICE = "com.termux.app.RunCommandService"
        private const val VERSION_COMPONENT_COUNT = 2
        private const val MIN_PROTOCOL_MINOR_VERSION = 109
    }
}
