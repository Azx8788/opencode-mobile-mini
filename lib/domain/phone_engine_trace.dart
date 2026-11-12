/// The exact shape a native start trace may take before it reaches the log:
/// ASCII stages joined by `;`, each `stage@elapsedMs` with `key=value` inside.
///
/// This mirrors `PhoneEngineTrace` in `BuiltinLinux.kt` character for
/// character. A detail that does not match is **dropped**, never rewritten: a
/// path, a command line or a password must not be logged, and a rewritten
/// trace would no longer be what native code actually produced. The round-trip
/// is pinned by `test/phone_engine_trace_test.dart`.
final _nativeTraceShape = RegExp(r'^[A-Za-z0-9_$.,;:=@-]+$');

/// The same bound `PhoneEngineTrace.LIMIT` enforces before a detail leaves
/// native code; a longer detail is not a trace and is not logged.
const nativeTraceLimit = 240;

String? nativeTraceText(String? details) {
  final value = details?.trim();
  if (value == null || value.isEmpty || value.length > nativeTraceLimit) {
    return null;
  }
  return _nativeTraceShape.hasMatch(value) ? value : null;
}
