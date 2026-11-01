package com.azx8788.opencode.mini

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.Settings

internal object MainActivityBuiltinSupport {
    fun openStorageSettingsIntent(activity: Activity): Boolean {
        val candidates = listOf(
            Intent(Settings.ACTION_INTERNAL_STORAGE_SETTINGS),
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${activity.packageName}"),
            ),
        )
        for (intent in candidates) {
            try {
                activity.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: ActivityNotFoundException) {
                // The next candidate.
            } catch (_: SecurityException) {
                // Not exported on this build; try the next one.
            }
        }
        return false
    }

    fun setupSpec(raw: Map<String, Any?>): SetupRunner.Spec {
        fun strings(value: Any?): Map<String, String> =
            (value as? Map<*, *>)?.entries
                ?.filter { it.key is String && it.value is String }
                ?.associate { it.key as String to it.value as String }
                .orEmpty()
        return SetupRunner.Spec(
            id = raw["id"] as? String ?: error("A setup component needs an id"),
            script = raw["script"] as? String,
            native = raw["native"] == true,
            step = raw["step"] == true,
            weight = (raw["weight"] as? Number)?.toDouble() ?: 1.0,
            skipped = raw["skipped"] == true,
            version = raw["version"] as? String,
            stage = raw["stage"] as? String,
            labels = strings(raw["labels"]),
            data = strings(raw["data"]),
            agentUser = raw["agentUser"] == true,
        )
    }

}
