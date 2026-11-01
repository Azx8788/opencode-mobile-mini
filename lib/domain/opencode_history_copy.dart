/// Carries OpenCode 1 chats into OpenCode 2's own data folder.
///
/// OpenCode 2 converts OpenCode 1 history by itself on every start, but only
/// from the `opencode.db` it finds in its own `$XDG_DATA_HOME/opencode/`
/// (probed on 2.0.29: `docs/qa/oc2-switch-keeps-chats-2026-10-14/`). The
/// switch gives OpenCode 2 an isolated data folder, so without this copy the
/// old chats stay behind.
///
/// POSIX `sh`, meant to run inside the Ubuntu container before OpenCode 2's
/// first start, after OpenCode 1 has stopped:
///
/// - runs only when OpenCode 2 has no `opencode.db` yet, so it never
///   overwrites and a second switch is a no-op;
/// - copies, never moves: OpenCode 1's original folder remains untouched;
/// - stages the database with its `-wal` and `-shm` files in a scratch folder
///   and moves them into place with `opencode.db` last, so a half copy never
///   looks like a database;
/// - refuses a fresh start on any copy failure; never starts with missing history.
///
/// Existing targets remain untouched on ordinary restarts. Explicit moves must
/// run [openCode1HistorySwitchCheckScript] first, before stopping OpenCode 1.
const _historyCopyProvenance = r'''
history_source_signature() (
  cd "$1" || exit 1
  for history_file in opencode.db opencode.db-wal opencode.db-shm; do
    [ ! -L "$history_file" ] || exit 1
    if [ -e "$history_file" ]; then
      [ -f "$history_file" ] || exit 1
      sha256sum "$history_file" || exit 1
    else
      printf 'absent %s\n' "$history_file"
    fi
  done
)
history_copy_receipt_matches() {
  [ -f "$oc2_dir/.oc1-import-source.sha256" ] &&
  [ ! -L "$oc2_dir/.oc1-import-source.sha256" ] || return 1
  history_signature=$(history_source_signature "$oc1_dir") || return 1
  [ "$(cat "$oc2_dir/.oc1-import-source.sha256")" = "$history_signature" ]
}
''';

const openCode1HistoryCopyScript =
    _historyCopyProvenance +
    r'''
oc1_dir="${HOME:-/root}/.local/share/opencode"
oc2_dir=/root/.oc-opencode2/data/opencode
if [ ! -e "$oc2_dir/opencode.db" ] && [ -f "$oc1_dir/opencode.db" ]; then
  history_copy_failed() {
    echo '[oc-history-copy-failed] Your earlier conversations could not be copied. The original data is still safe on this phone. Free some space and try again.' >&2
    exit 74
  }
  [ ! -L "$oc1_dir" ] && [ ! -L "$oc2_dir" ] || history_copy_failed
  original_signature=$(history_source_signature "$oc1_dir") || history_copy_failed
  # Only our own verified interrupted copy may leave target sidecars.
  if [ -e "$oc2_dir/opencode.db-wal" ] || [ -e "$oc2_dir/opencode.db-shm" ]; then
    history_copy_receipt_matches || history_copy_failed
    for history_file in opencode.db-wal opencode.db-shm; do
      if [ -e "$oc2_dir/$history_file" ]; then
        [ ! -L "$oc2_dir/$history_file" ] &&
        cmp -s "$oc1_dir/$history_file" "$oc2_dir/$history_file" || history_copy_failed
      fi
    done
    rm -f "$oc2_dir/opencode.db-wal" "$oc2_dir/opencode.db-shm" || history_copy_failed
  fi
  mkdir -p "$oc2_dir" || history_copy_failed
  stage="$oc2_dir/.oc1-copy.$$"
  # Do not reuse an interrupted staging folder or follow a stale symlink.
  mkdir "$stage" || history_copy_failed
  if ! { cp "$oc1_dir/opencode.db" "$stage/opencode.db" \
    && { [ ! -f "$oc1_dir/opencode.db-wal" ] || cp "$oc1_dir/opencode.db-wal" "$stage/opencode.db-wal"; } \
    && { [ ! -f "$oc1_dir/opencode.db-shm" ] || cp "$oc1_dir/opencode.db-shm" "$stage/opencode.db-shm"; }; }; then
    rm -rf "$stage"
    history_copy_failed
  fi
  # Commit provenance before the database. A crash after the database rename
  # can then safely retry admission, including after OC2 has converted it.
  copied_signature=$(history_source_signature "$stage") || history_copy_failed
  [ "$copied_signature" = "$original_signature" ] || history_copy_failed
  [ "$(history_source_signature "$oc1_dir")" = "$original_signature" ] || history_copy_failed
  printf '%s\n' "$copied_signature" > "$stage/.oc1-import-source.sha256" || history_copy_failed
  mv "$stage/.oc1-import-source.sha256" "$oc2_dir/.oc1-import-source.sha256" || history_copy_failed
  if ! { { [ ! -f "$stage/opencode.db-wal" ] || mv "$stage/opencode.db-wal" "$oc2_dir/opencode.db-wal"; } \
    && { [ ! -f "$stage/opencode.db-shm" ] || mv "$stage/opencode.db-shm" "$oc2_dir/opencode.db-shm"; } \
    && mv "$stage/opencode.db" "$oc2_dir/opencode.db"; }; then
    rm -rf "$stage"
    history_copy_failed
  fi
  rm -rf "$stage"
fi
''';

const openCode1HistorySwitchBlockedMessage =
    'Cannot move your conversations because OpenCode 2 already has a separate '
    'history. The automatic move stopped to protect your conversations. '
    'Both histories are safe; neither was changed.';

/// Read-only admission for an explicit move from Older OpenCode to OpenCode 2.
/// Run before stopping the old server or changing its profile/credentials.
/// The current OC2 API reports migration status but has no verified merge path
/// for two existing histories. Refusing leaves both histories untouched.
const openCode1HistorySwitchCheckScript =
    _historyCopyProvenance +
    r'''
oc1_dir="${HOME:-/root}/.local/share/opencode"
oc2_dir=/root/.oc-opencode2/data/opencode
# Unknown locations must not be mistaken for an absent history.
for history_dir in "$oc1_dir" "$oc2_dir"; do
  if [ -L "$history_dir" ] || { [ -e "$history_dir" ] && { [ ! -d "$history_dir" ] || [ ! -r "$history_dir" ] || [ ! -x "$history_dir" ]; }; } \
    || [ -L "$history_dir/opencode.db" ]; then
    echo '[oc-history-switch-blocked] Cannot check your earlier conversations safely. The automatic move stopped. Neither history was changed.' >&2
    exit 74
  fi
done
if [ -e "$oc1_dir/opencode.db" ] && [ -e "$oc2_dir/opencode.db" ] && ! history_copy_receipt_matches; then
  echo '[oc-history-switch-blocked] Cannot move your conversations because OpenCode 2 already has a separate history. The automatic move stopped to protect your conversations. Both histories are safe; neither was changed.' >&2
  exit 74
fi
''';

/// Read-only result of the same check used immediately before a move.
/// Unknown or failed checks never authorize a promise that chats will move.
enum OpenCodeHistorySwitchAdmission {
  allowed,
  separateHistory,
  unavailable;

  static OpenCodeHistorySwitchAdmission fromResult(
    int exitCode,
    String output,
  ) {
    if (exitCode == 0) return allowed;
    if (exitCode == 74 &&
        output.contains(openCode1HistorySwitchBlockedMessage)) {
      return separateHistory;
    }
    return unavailable;
  }
}
