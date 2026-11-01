package com.azx8788.opencode.mini

/** Pure shell protocol builder; kept separate for a host-side lifecycle harness. */
object TermuxSetupShell {
    fun quote(value: String) = "'" + value.replace("'", "'\\''") + "'"
    private fun directory(job: String) = "d=\"\$HOME/.oc/setup-v2/$job\"\n"

    fun launch(job: String, specs: List<Map<String, Any?>>): String {
        val body = StringBuilder(COMMON)
        body.append(directory(job))
        body.append("mkdir -p \"\$d\"\nexec 8>\"\$d/lock\"\nflock -n 8 || exit 0\n")
        body.append("exec 9>\"\$HOME/.oc/setup-v2/install.lock\"\nflock -n 9 || { put state failed; exit 0; }\n")
        body.append(OWNER)
        for (spec in specs) {
            val id = spec["id"] as String
            body.append("put current ${quote(id)}\n")
            if (spec["skipped"] == true) {
                body.append("put ${quote("$id.state")} skipped\n")
                continue
            }
            body.append("put ${quote("$id.state")} running\n")
            if (spec["step"] == true) {
                body.append("while [ ! -f \"\$d/$id.ack\" ]; do sleep 1; done\n")
                body.append("[ \"\$(cat \"\$d/$id.ack\")\" = ok ] || { put $id.state failed; put state failed; exit 0; }\n")
            } else {
                val script = spec["script"] as? String ?: error("Component needs an install script")
                val command = if (spec["native"] == true) "bash -c ${quote(script)}" else
                    "proot-distro login opencode-ubuntu -- /bin/bash -c ${quote(script)}"
                body.append("$command 2>&1 | progress ${quote(id)}\n")
                body.append("rc=\${PIPESTATUS[0]}\n[ \"\$rc\" = 0 ] || { put $id.state failed; put state failed; exit 0; }\n")
            }
            body.append("put ${quote("$id.state")} done\n")
        }
        body.append("put state done\n")
        return "command -v flock >/dev/null && command -v setsid >/dev/null || exit 69\n" +
            "umask 077\nmkdir -p \"\$HOME/.oc/setup-v2/$job\"\n" +
            "nohup setsid bash -c ${quote(body.toString())} </dev/null >/dev/null 2>&1 &\n" +
            directory(job) +
            "for attempt in {1..50}; do [ -f \"\$d/owner\" ] || [ -f \"\$d/state\" ] || { sleep 0.1; continue; }; break; done\n"
    }

    fun probe(job: String): String = COMMON + directory(job) + PROBE
    fun cancel(job: String): String = COMMON + directory(job) + CANCEL
    fun complete(job: String, id: String, ok: Boolean): String = COMMON + directory(job) +
        "[ \"\$(cat \"\$d/current\" 2>/dev/null)\" = ${quote(id)} ] || exit 0\n" +
        "[ \"\$(cat \"\$d/state\" 2>/dev/null)\" = running ] || exit 0\n" +
        "[ -f \"\$d/$id.ack\" ] || put ${quote("$id.ack")} ${if (ok) "ok" else "failed"}\n"

    private val COMMON = """
        umask 077
        put() { printf '%s\n' "${'$'}2" > "${'$'}d/${'$'}1.tmp" && mv -f "${'$'}d/${'$'}1.tmp" "${'$'}d/${'$'}1"; }
        progress() {
          local line value done total
          while IFS= read -r line; do
            case "${'$'}line" in
              '::oc percent '*)
                value="${'$'}{line#::oc percent }"
                if [[ "${'$'}value" =~ ^[0-9]{1,3}([.][0-9]{1,3})?${'$'} ]]; then put "${'$'}1.percent" "${'$'}value"; fi ;;
              '::oc bytes '*)
                read -r done total <<< "${'$'}{line#::oc bytes }"
                if [[ "${'$'}done" =~ ^[0-9]{1,18}${'$'} && "${'$'}total" =~ ^[0-9]{1,18}${'$'} ]]; then
                  put "${'$'}1.done" "${'$'}done"; put "${'$'}1.total" "${'$'}total"
                fi ;;
            esac
          done
        }
    """.trimIndent() + "\n"

    private val OWNER = """
        [ ! -f "${'$'}d/cancel" ] || { put state cancelled; exit 0; }
        [ ! -f "${'$'}d/owner" ] || exit 0
        put owner "${'$'}${'$'} ${'$'}(awk '{print ${'$'}22}' /proc/${'$'}${'$'}/stat) ${'$'}(cat /proc/sys/kernel/random/boot_id)"
        stop_job() {
          trap '' TERM INT
          put cancel 1
          kill -TERM -- -"${'$'}${'$'}" 2>/dev/null || true
          sleep 2
          kill -KILL -- -"${'$'}${'$'}" 2>/dev/null || true
          exit 1
        }
        trap stop_job TERM INT
        [ ! -f "${'$'}d/cancel" ] || { put state cancelled; exit 0; }
        put state running
    """.trimIndent() + "\n"

    private val PROBE = """
        mkdir -p "${'$'}d"
        # Fence a launch that was queued when the app died. Holding this same
        # lock makes the missing-owner decision atomic with launch ownership.
        (
          flock -n 8 || exit 0
          if [ ! -f "${'$'}d/owner" ] && [ ! -f "${'$'}d/state" ]; then
            put cancel 1
            put state interrupted
          fi
        ) 8>"${'$'}d/lock"
        state="${'$'}(cat "${'$'}d/state" 2>/dev/null)"
        if [ -f "${'$'}d/owner" ]; then
          if flock -n "${'$'}d/lock" true; then
            case "${'$'}state" in done|failed|cancelled) ;; *)
              if [ -f "${'$'}d/cancel" ]; then state=cancelled; else state=interrupted; fi ;;
            esac
          else state=running
          fi
        elif [ -f "${'$'}d/cancel" ] && [ "${'$'}state" != interrupted ]; then state=cancelled
        fi
        printf 'state|%s\n' "${'$'}state"
        printf 'current|%s\n' "${'$'}(cat "${'$'}d/current" 2>/dev/null)"
        for f in "${'$'}d/"*.state; do
          [ -f "${'$'}f" ] || continue
          id="${'$'}{f##*/}"; id="${'$'}{id%.state}"
          printf 'component|%s|%s|%s|%s|%s\n' "${'$'}id" "${'$'}(cat "${'$'}f")" "${'$'}(cat "${'$'}d/${'$'}id.percent" 2>/dev/null)" "${'$'}(cat "${'$'}d/${'$'}id.done" 2>/dev/null)" "${'$'}(cat "${'$'}d/${'$'}id.total" 2>/dev/null)"
        done
    """.trimIndent() + "\n"

    private val CANCEL = """
        mkdir -p "${'$'}d"
        put cancel 1
        [ -f "${'$'}d/owner" ] || exit 0
        read -r pid start boot < "${'$'}d/owner"
        [[ "${'$'}pid" =~ ^[0-9]+${'$'} ]] || exit 0
        [ "${'$'}boot" = "${'$'}(cat /proc/sys/kernel/random/boot_id)" ] || exit 0
        [ "${'$'}start" = "${'$'}(awk '{print ${'$'}22}' /proc/"${'$'}pid"/stat 2>/dev/null)" ] || exit 0
        [ "${'$'}pid" = "${'$'}(awk '{print ${'$'}5}' /proc/"${'$'}pid"/stat 2>/dev/null)" ] || exit 0
        flock -n "${'$'}d/lock" true && exit 0
        kill -TERM -- -"${'$'}pid" 2>/dev/null || true
    """.trimIndent() + "\n"
}
