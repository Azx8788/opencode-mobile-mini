package com.azx8788.opencode.mini

import org.json.JSONObject

internal const val MAX_SCHEDULE_HISTORY = 256

internal fun scheduleClaimsKey(profile: String) = "flutter.oc.scheduleClaims.$profile"

internal fun ScheduledPromptStore.claimsFor(profile: String): JSONObject =
    JSONObject(prefs.getString(scheduleClaimsKey(profile), "{}") ?: "{}")

internal fun ScheduledPromptStore.claim(entry: ScheduledPromptStore.Entry): String =
    synchronized(ScheduledPromptStore.lock) {
        if (!profileExists(entry.profileId) || !claimable(entry)) "stale" else reserve(entry)
    }

private fun ScheduledPromptStore.claimable(entry: ScheduledPromptStore.Entry): Boolean {
    val current = entries(entry.profileId).firstOrNull { it.id == entry.id }
    return ScheduledPromptPolicy.canClaim(current?.revision, current?.due, entry.revision, entry.due, false)
}

private fun ScheduledPromptStore.reserve(entry: ScheduledPromptStore.Entry): String {
    val claims = claimsFor(entry.profileId)
    val existing = claims.optJSONObject(entry.occurrence)
    if (existing != null) return recoverClaim(entry, claims, existing)
    claims.put(entry.occurrence, JSONObject().put("at", System.currentTimeMillis()).put("finished", false))
    trimClaims(claims)
    return if (storeClaims(entry.profileId, claims)) "new" else "stale"
}

private fun ScheduledPromptStore.recoverClaim(
    entry: ScheduledPromptStore.Entry,
    claims: JSONObject,
    existing: JSONObject,
): String {
    if (existing.optBoolean("finished")) return "duplicate"
    // A fresh recovery reservation can only write interrupted history, never send.
    existing.put("at", System.currentTimeMillis())
    return if (storeClaims(entry.profileId, claims)) "recover" else "stale"
}

internal fun ScheduledPromptStore.storeClaims(profile: String, claims: JSONObject): Boolean =
    prefs.edit().putString(scheduleClaimsKey(profile), claims.toString()).commit()

/** Keep bounded history. Old occurrences cannot re-enter through the current index. */
private fun trimClaims(claims: JSONObject) {
    if (claims.length() <= MAX_SCHEDULE_HISTORY) return
    claims.keys().asSequence().toList().sortedBy { claims.optJSONObject(it)?.optLong("at") ?: 0L }
        .take(claims.length() - MAX_SCHEDULE_HISTORY).forEach { claims.remove(it) }
}
