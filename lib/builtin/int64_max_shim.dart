// Web seam: a browser number cannot hold the signed 64-bit maximum, so the
// browser build (the Widgetbook catalog only) saturates at 2^53 - 1 instead.
// Every native build keeps the exact value.
export 'int64_max_native.dart'
    if (dart.library.js_interop) 'int64_max_web.dart';
