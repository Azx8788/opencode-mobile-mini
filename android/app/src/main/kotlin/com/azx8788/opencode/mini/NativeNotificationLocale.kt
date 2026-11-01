package com.azx8788.opencode.mini

import android.app.NotificationManager
import android.content.Context

/** Refreshes existing native surfaces without restarting a service or changing permissions. */
object NativeNotificationLocale {
    private val channels = listOf(
        Channel("opencode_live_connection", R.string.native_live_channel, R.string.native_live_description),
        Channel("opencode_coding_action", R.string.native_coding_requests_channel,
            R.string.native_coding_requests_description),
        Channel("opencode_coding_status", R.string.native_coding_status_channel,
            R.string.native_coding_status_description),
        Channel("opencode_team_progress", R.string.native_team_progress_channel,
            R.string.native_team_progress_description),
        Channel("opencode_builtin_server", R.string.native_phone_server_channel,
            R.string.native_phone_server_description),
        Channel("opencode_voice_setup", R.string.native_voice_setup),
    )

    fun refresh(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        for (copy in channels) {
            val channel = manager.getNotificationChannel(copy.id) ?: continue
            channel.name = NativeStrings.get(context, copy.name)
            copy.description?.let { channel.description = NativeStrings.get(context, it) }
            // Reuse the existing channel object: Android retains the user's
            // importance/sound choices and this only changes app-authored copy.
            manager.createNotificationChannel(channel)
        }
        BackgroundConnectionService.refreshLocale(context)
        SessionsWidgetProvider.refreshAll(context)
        UsageWidgetProvider.refreshAll(context)
    }

    private data class Channel(val id: String, val name: Int, val description: Int? = null)
}
