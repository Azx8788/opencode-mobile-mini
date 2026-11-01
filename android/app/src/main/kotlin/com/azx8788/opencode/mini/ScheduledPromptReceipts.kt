package com.azx8788.opencode.mini

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

internal fun scheduleReceiptKey(profile: String) = "flutter.oc.scheduleReceipts.$profile"

internal fun ScheduledPromptStore.receipts(profile: String): List<Map<String, Any?>> =
    synchronized(ScheduledPromptStore.lock) {
        if (!profileExists(profile)) return@synchronized emptyList()
        val array = JSONArray(prefs.getString(scheduleReceiptKey(profile), "[]"))
        (0 until array.length()).map { i ->
            array.getJSONObject(i).let { row ->
                row.keys().asSequence().associateWith { row.opt(it) }
            }
        }
    }

internal fun ScheduledPromptStore.acknowledge(profile: String, ids: Set<String>) =
    synchronized(ScheduledPromptStore.lock) {
        if (!profileExists(profile)) return@synchronized
        val remaining = JSONArray()
        receipts(profile).filter { it["id"] !in ids }.forEach { remaining.put(JSONObject(it)) }
        check(prefs.edit().putString(scheduleReceiptKey(profile), remaining.toString()).commit())
    }

/** Stages a failed-run receipt on [edit]; the caller commits it with the claim update. */
internal fun ScheduledPromptStore.stageFailedReceipt(
    entry: ScheduledPromptStore.Entry,
    failure: String,
    edit: SharedPreferences.Editor,
) {
    val key = scheduleReceiptKey(entry.profileId)
    val receipts = JSONArray(prefs.getString(key, "[]"))
    receipts.put(
        JSONObject().put("id", entry.occurrence).put("scheduleId", entry.id)
            .put("revision", entry.revision).put("scheduledAtMs", entry.due)
            .put("finishedAtMs", System.currentTimeMillis()).put("status", "failed").put("error", failure),
    )
    while (receipts.length() > MAX_SCHEDULE_HISTORY) receipts.remove(0)
    edit.putString(key, receipts.toString())
}
