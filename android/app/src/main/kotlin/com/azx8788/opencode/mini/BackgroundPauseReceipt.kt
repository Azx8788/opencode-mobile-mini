package com.azx8788.opencode.mini

/** Only fixed categories and timestamps are persisted; no OS description. */
data class BackgroundPauseReceipt(
    val phase: String = "none",
    val reason: String = "none",
    val at: Long = 0L,
)

data class BackgroundPauseExit(val reason: Int, val at: Long)

/** What the app sees now. [bootAt] is the wall-clock boot time (now - elapsedRealtime); 0 = unknown. */
data class BackgroundPauseObservation(
    val active: Boolean,
    val restricted: Boolean,
    val exit: BackgroundPauseExit?,
    val now: Long,
    val bootAt: Long = 0L,
)

object BackgroundPausePolicy {
    const val TIME_LIMIT = "timeLimit"
    const val BATTERY_RESTRICTED = "batteryRestricted"
    const val USER_STOPPED = "userStopped"
    const val INTERRUPTED = "interrupted"
    const val APP_UPDATED = "appUpdated"
    const val DEVICE_RESTARTED = "deviceRestarted"
    /** Wall-clock slack when comparing a receipt with the boot time. */
    private const val BOOT_SLACK_MS = 60_000L
    private const val USER_REQUESTED_EXIT = 10
    private const val USER_STOPPED_EXIT = 11
    private const val PACKAGE_UPDATED_EXIT = 16

    fun reconcile(receipt: BackgroundPauseReceipt, seen: BackgroundPauseObservation): BackgroundPauseReceipt = when {
        seen.active ->
            if (receipt.phase == "running") receipt else BackgroundPauseReceipt("running", at = seen.now)
        receipt.phase != "running" -> {
            // A current-policy statement must not become a historical cause.
            if (receipt.reason == BATTERY_RESTRICTED && !seen.restricted) {
                receipt.copy(reason = INTERRUPTED)
            } else receipt
        }
        else -> interrupted(receipt, seen)
    }

    private fun interrupted(receipt: BackgroundPauseReceipt, seen: BackgroundPauseObservation): BackgroundPauseReceipt {
        val reason = interruptionReason(receipt, seen)
        // Battery policy is observed now. The exit timestamp is evidence
        // only when it actually followed this receipt's running period.
        val at = if (reason == USER_STOPPED || reason == APP_UPDATED) checkNotNull(seen.exit).at else seen.now
        return BackgroundPauseReceipt("paused", reason, at)
    }

    private fun interruptionReason(receipt: BackgroundPauseReceipt, seen: BackgroundPauseObservation): String = when {
        seen.restricted -> BATTERY_RESTRICTED
        isExitAfter(seen.exit, receipt.at, USER_REQUESTED_EXIT, USER_STOPPED_EXIT) -> USER_STOPPED
        // An app update ends the process: a known cause, not "unknown".
        isExitAfter(seen.exit, receipt.at, PACKAGE_UPDATED_EXIT) -> APP_UPDATED
        // The receipt was written before the phone booted: it restarted.
        seen.bootAt > 0L && receipt.at < seen.bootAt - BOOT_SLACK_MS -> DEVICE_RESTARTED
        else -> INTERRUPTED
    }

    private fun isExitAfter(exit: BackgroundPauseExit?, startedAt: Long, vararg reasons: Int): Boolean =
        exit != null && exit.at > startedAt && exit.reason in reasons
}
