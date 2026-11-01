package com.azx8788.opencode.mini

/** Bound untrusted intent text before parking or forwarding it to Dart.
 * No decoding or logging: the Dart domain parser owns the versioned format.
 */
internal object SessionLinkIngress {
    fun accepts(value: String): Boolean =
        value.isNotEmpty() && value.length <= 1024 && value.all { it.code in 0x21..0x7e }
}
