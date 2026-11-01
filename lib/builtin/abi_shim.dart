// Web seam: `dart:ffi` does not exist in a browser build, and three setup
// files only need `Abi`. On every native build this re-exports the real one,
// so behaviour is unchanged; the web stub exists so the Widgetbook catalog can
// compile the app's screens.
export 'abi_native.dart' if (dart.library.js_interop) 'abi_web.dart';
