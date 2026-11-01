package com.azx8788.opencode.mini

import android.content.SharedPreferences
import java.time.ZoneId
import org.json.JSONArray
import org.json.JSONObject

/** The Dart not_due result proves this attempt never crossed prompt admission. */
internal fun ScheduledPromptStore.deferEarlyOccurrence(
    entry: ScheduledPromptStore.Entry,
    now: Long,
    recovering: Boolean,
): Boolean = synchronized(ScheduledPromptStore.lock) {
    val runs = deferrableRuns(entry, now)
    // Prior uncertain execution remains recovery-only even across a clock
    // rollback. Only a fresh, unrecorded attempt may become claimable again.
    if (runs != null && !recovering && !runs.records(entry.occurrence)) {
        val claims = claimsFor(entry.profileId)
        claims.remove(entry.occurrence)
        check(storeClaims(entry.profileId, claims))
    }
    runs != null
}

private fun ScheduledPromptStore.deferrableRuns(entry: ScheduledPromptStore.Entry, now: Long): JSONArray? {
    val unfinished = claimsFor(entry.profileId).optJSONObject(entry.occurrence)?.optBoolean("finished") == false
    val eligible = entry.due > now && occurrenceCurrent(entry) && unfinished
    if (!eligible) return null
    return prefs.getString("flutter.oc.scheduledPrompts.${entry.profileId}", null)
        ?.let { JSONObject(it).getJSONArray("runs") }
}

private fun JSONArray.records(id: String): Boolean =
    (0 until length()).any { getJSONObject(it).getString("id") == id }

internal fun ScheduledPromptStore.settle(entry: ScheduledPromptStore.Entry, failure: String? = null) =
    synchronized(ScheduledPromptStore.lock) {
        if (!profileExists(entry.profileId)) return@synchronized
        val claims = claimsFor(entry.profileId)
        claims.optJSONObject(entry.occurrence)?.put("finished", true)
        val edit = prefs.edit().putString(scheduleClaimsKey(entry.profileId), claims.toString())
        if (failure != null && stageFailure(entry, failure, edit)) stageFailedReceipt(entry, failure, edit)
        check(edit.commit())
    }

/** Repairs the envelope on [edit]; true when the failure is worth a receipt. */
private fun ScheduledPromptStore.stageFailure(
    entry: ScheduledPromptStore.Entry,
    failure: String,
    edit: SharedPreferences.Editor,
): Boolean {
    val dataKey = "flutter.oc.scheduledPrompts.${entry.profileId}"
    val target = ScheduledPromptRecovery.Target(entry.id, entry.revision, entry.due)
    val repaired = prefs.getString(dataKey, null)?.let { JSONObject(it) }?.takeIf {
        ScheduledPromptRecovery.repair(it, target, System.currentTimeMillis(), failure, ZoneId.systemDefault())
    }
    repaired?.let { edit.putString(dataKey, it.toString()) }
    return repaired != null || entry.id == "__digest"
}

internal fun ScheduledPromptStore.clear(profile: String) = synchronized(ScheduledPromptStore.lock) {
    check(
        prefs.edit().putBoolean("flutter.oc.scheduleDeleted.$profile", true).remove(indexKey(profile))
            .remove(scheduleClaimsKey(profile)).remove(scheduleReceiptKey(profile)).commit(),
    )
}
