package com.azx8788.opencode.mini

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * One lock shared by UI and headless engines. No credentials enter the native index.
 * Calendar, claim and receipt operations live in ScheduledPromptCalendar.kt,
 * ScheduledPromptClaims.kt and ScheduledPromptReceipts.kt as extensions that take the same lock.
 */
internal class ScheduledPromptStore(internal val prefs: SharedPreferences) {
    constructor(context: Context) : this(
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE),
    )

    data class Entry(val profileId: String, val id: String, val revision: Long, val due: Long) {
        val occurrence get() = ScheduledPromptPolicy.occurrence(id, revision, due)
        val workName get() = "oc.schedule.$profileId.$occurrence"

        companion object {
            /** Routing data from an alarm or work request; null when any part is unsafe. */
            fun orNull(profileId: String, id: String, revision: Long, due: Long): Entry? =
                if (ScheduledPromptPolicy.validId(profileId) &&
                    ScheduledPromptPolicy.validOccurrence(id, revision, due)) {
                    Entry(profileId, id, revision, due)
                } else {
                    null
                }
        }
    }

    fun profileExists(profile: String): Boolean = synchronized(lock) {
        if (prefs.getBoolean("flutter.oc.scheduleDeleted.$profile", false)) return@synchronized false
        val profiles = runCatching { JSONArray(prefs.getString("flutter.oc.profiles", "[]")) }.getOrNull()
        profiles != null && (0 until profiles.length()).any { profiles.optJSONObject(it)?.optString("id") == profile }
    }

    fun read(key: String): String? = synchronized(lock) {
        validateKey(key)
        check(profileExists(key.removePrefix(KEY_PREFIX)))
        prefs.getString("flutter.$key", null)
    }

    fun cas(key: String, expected: String?, value: String?): Boolean = synchronized(lock) {
        validateKey(key)
        val stale = !profileExists(key.removePrefix(KEY_PREFIX)) ||
            prefs.getString("flutter.$key", null) != expected
        if (stale) return@synchronized false
        val editor = prefs.edit()
        if (value == null) editor.remove("flutter.$key") else editor.putString("flutter.$key", value)
        editor.commit()
    }

    fun entries(profile: String): List<Entry> = synchronized(lock) {
        val array = runCatching { JSONArray(prefs.getString(indexKey(profile), "[]")) }.getOrNull()
            ?: return@synchronized emptyList()
        (0 until array.length()).mapNotNull { index ->
            val row = array.optJSONObject(index) ?: return@mapNotNull null
            val id = row.optString("id")
            val revision = row.optLong("revision", -1)
            val due = row.optLong("dueAtMs", -1)
            if (ScheduledPromptPolicy.validOccurrence(id, revision, due)) Entry(profile, id, revision, due) else null
        }
    }

    fun restoreProfile(profile: String) = synchronized(lock) {
        check(prefs.edit().remove("flutter.oc.scheduleDeleted.$profile").commit())
    }

    fun replace(profile: String): Boolean = synchronized(lock) {
        require(ScheduledPromptPolicy.validId(profile))
        if (!profileExists(profile)) return@synchronized false
        val array = JSONArray()
        currentEntries(profile).forEach {
            array.put(JSONObject().put("id", it.id).put("revision", it.revision).put("dueAtMs", it.due))
        }
        prefs.edit().putString(indexKey(profile), array.toString()).commit()
    }

    internal fun indexKey(profile: String) = "flutter.oc.scheduleIndex.$profile"

    private fun validateKey(key: String) {
        require(key.startsWith(KEY_PREFIX) && ScheduledPromptPolicy.validId(key.removePrefix(KEY_PREFIX)))
    }

    companion object {
        internal val lock = Any()
        private const val KEY_PREFIX = "oc.scheduledPrompts."
    }
}
