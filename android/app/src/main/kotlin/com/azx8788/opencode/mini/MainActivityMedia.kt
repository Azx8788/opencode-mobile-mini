package com.azx8788.opencode.mini

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Activity-owned camera and voice permission replies survive channel reconfiguration. */
internal class MainActivityMedia(
    private val activity: Activity,
    private val beforeMicrophoneCapture: () -> Boolean,
) {
    private var microphonePermissionResult: MethodChannel.Result? = null
    private var cameraPermissionResult: MethodChannel.Result? = null
    private val voiceDownloadNotifications by lazy { VoiceDownloadNotifications(activity) }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "oc/voice").setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceInfo" -> result.success(voiceDeviceInfo())
                "requestMicrophonePermission" -> requestMicrophonePermission(result)
                "openAppSettings" -> openAppSettings(result)
                else -> if (!voiceDownloadNotifications.handle(call, result)) result.notImplemented()
            }
        }
        MethodChannel(messenger, "oc/camera").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasCamera" -> result.success(
                    activity.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
                )
                "requestCameraPermission" -> requestCameraPermission(result)
                "openAppSettings" -> openAppSettings(result)
                else -> result.notImplemented()
            }
        }
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        return when {
            voiceDownloadNotifications.onPermissionResult(requestCode, grantResults) -> true
            StorageAccess.onPermissionResult(activity, requestCode) -> true
            requestCode == MICROPHONE_PERMISSION_REQUEST -> {
                completeMicrophonePermission(granted)
                true
            }
            requestCode == CAMERA_PERMISSION_REQUEST -> {
                val result = cameraPermissionResult
                cameraPermissionResult = null
                result?.success(permissionStatus(Manifest.permission.CAMERA, granted))
                true
            }
            else -> false
        }
    }

    fun dispose() {
        voiceDownloadNotifications.dispose()
    }

    private fun completeMicrophonePermission(granted: Boolean) {
        val result = microphonePermissionResult ?: return
        microphonePermissionResult = null
        if (granted && !beforeMicrophoneCapture()) {
            result.error("voice_unavailable", "Local voice input is unavailable.", null)
        } else {
            result.success(permissionStatus(Manifest.permission.RECORD_AUDIO, granted))
        }
    }

    private fun permissionStatus(permission: String, granted: Boolean): String = when {
        granted -> "granted"
        !activity.shouldShowRequestPermissionRationale(permission) -> "permanentlyDenied"
        else -> "denied"
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        activity.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))
        )
        result.success(null)
    }

    private fun voiceDeviceInfo(): Map<String, Any> {
        val storage = StatFs(activity.filesDir.absolutePath)
        val activityManager = activity.getSystemService(ActivityManager::class.java)
        // Speech models use native memory, so report device memory as well as the Java heap limit.
        val memory = ActivityManager.MemoryInfo().also(activityManager::getMemoryInfo)
        return mapOf(
            "availableStorageBytes" to storage.availableBytes,
            "memoryClassMb" to activityManager.memoryClass,
            "totalMemoryMb" to (memory.totalMem / BYTES_PER_MEBIBYTE),
            "lowRamDevice" to activityManager.isLowRamDevice,
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
            "hasMicrophone" to activity.packageManager.hasSystemFeature(PackageManager.FEATURE_MICROPHONE)
        )
    }

    private fun requestCameraPermission(result: MethodChannel.Result) {
        if (activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            result.success("granted")
            return
        }
        val preferences = activity.getSharedPreferences("camera_permissions", Activity.MODE_PRIVATE)
        when {
            preferences.getBoolean("camera_requested", false) &&
                !activity.shouldShowRequestPermissionRationale(Manifest.permission.CAMERA) ->
                result.success("permanentlyDenied")
            cameraPermissionResult != null ->
                result.error("permission_in_progress", "A camera permission request is already open.", null)
            else -> {
                cameraPermissionResult = result
                preferences.edit().putBoolean("camera_requested", true).apply()
                activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION_REQUEST)
            }
        }
    }

    private fun requestMicrophonePermission(result: MethodChannel.Result) {
        if (!beforeMicrophoneCapture()) {
            result.error("voice_unavailable", "Local voice input is unavailable.", null)
            return
        }
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            result.success("granted")
            return
        }
        val preferences = activity.getSharedPreferences("voice_permissions", Activity.MODE_PRIVATE)
        when {
            preferences.getBoolean("microphone_requested", false) &&
                !activity.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) ->
                result.success("permanentlyDenied")
            microphonePermissionResult != null ->
                result.error("permission_in_progress", "A microphone permission request is already open.", null)
            else -> {
                microphonePermissionResult = result
                preferences.edit().putBoolean("microphone_requested", true).apply()
                val permissions = mutableListOf(Manifest.permission.RECORD_AUDIO)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                    PackageManager.PERMISSION_GRANTED
                ) {
                    permissions.add(Manifest.permission.POST_NOTIFICATIONS)
                }
                activity.requestPermissions(permissions.toTypedArray(), MICROPHONE_PERMISSION_REQUEST)
            }
        }
    }

    companion object {
        private const val MICROPHONE_PERMISSION_REQUEST = 4702
        private const val CAMERA_PERMISSION_REQUEST = 4704
        private const val BYTES_PER_MEBIBYTE = 1024L * 1024L
    }
}
