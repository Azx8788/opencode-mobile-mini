package com.azx8788.opencode.mini

/**
 * The one shape a start trace may take when it leaves native code: ASCII
 * `stage@elapsedMs` segments joined by `;`, with `key=value` inside a stage.
 *
 * It filters, it does not format: anything outside the alphabet is dropped, so
 * a path, a command line or a password can never ride along into the app log
 * even if a future gate embeds one. The Dart side accepts the same alphabet
 * and refuses anything else instead of rewriting it (see
 * `lib/domain/phone_engine_trace.dart`); the two are kept in step by
 * `test/phone_engine_trace_test.dart` and `PhoneEngineTraceTest.kt`.
 */
object PhoneEngineTrace {
    /** Upper bound for one trace, enforced before a detail leaves native code. */
    const val LIMIT = 240

    /** The alphabet, in one place: letters, digits and these separators. */
    private const val SEPARATORS = "_$.,;:=@-"

    /** ASCII cut marker: a clipped trace never looks like a complete one. */
    private const val CUT = "..."

    fun sanitize(value: String): String {
        val clean = buildString(value.length.coerceAtMost(LIMIT)) {
            for (character in value) {
                val ascii = character.code < 128
                if (ascii && (character.isLetterOrDigit() || SEPARATORS.indexOf(character) >= 0)) {
                    append(character)
                }
            }
        }
        return if (clean.length <= LIMIT) clean else clean.substring(0, LIMIT - CUT.length) + CUT
    }
}
