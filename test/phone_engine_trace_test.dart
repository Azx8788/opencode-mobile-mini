import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/phone_engine_trace.dart';

/// Every sample here is a trace the native side can actually produce; the
/// point is that the Dart filter returns it **unchanged**. A rewrite would
/// make the app log disagree with `adb logcat` about the same failure.
void main() {
  group('nativeTraceText', () {
    test('keeps a full gate trace character for character', () {
      const trace =
          'prepare@0;gate:unconfined=false,server=false,procs=0,svc=0,'
          'term=false@2;after:unconfined=false,server=false,procs=0,svc=0,'
          'term=false@3;tier=proot@3;proof:false,'
          'reason=boundary_unverified@9;spawned@210;'
          'status:boundary_false@214';
      expect(nativeTraceText(trace), trace);
    });

    test('keeps a refused-gate trace with its busy stage', () {
      const trace =
          'prepare@0;gate:unconfined=true,server=false,procs=0,svc=0,'
          'term=false@4;after:unconfined=true,server=false,procs=0,svc=0,'
          'term=false@1207;fail:restart_busy';
      expect(nativeTraceText(trace), trace);
    });

    test('keeps a credential write trace', () {
      const trace = 'write@0;fail:state';
      expect(nativeTraceText(trace), trace);
    });

    test('keeps a short class name from the unclassified bucket', () {
      const detail = 'IllegalStateException;op=writeServerPassword';
      expect(nativeTraceText(detail), detail);
    });

    test('drops a path, a command line and anything with spaces', () {
      expect(
        nativeTraceText('/data/user/0/com.azx8788.opencode.mini/x'),
        isNull,
      );
      expect(nativeTraceText('printf %s hunter2 > server.password'), isNull);
      expect(nativeTraceText('fail:重启'), isNull);
      expect(nativeTraceText('fail:reason\n'), 'fail:reason');
    });

    test('drops an empty or absent detail instead of logging a blank', () {
      expect(nativeTraceText(null), isNull);
      expect(nativeTraceText(''), isNull);
      expect(nativeTraceText('   '), isNull);
    });

    test('accepts exactly the limit and drops one character more', () {
      final atLimit = 'a' * nativeTraceLimit;
      expect(nativeTraceText(atLimit), atLimit);
      expect(nativeTraceText('a' * (nativeTraceLimit + 1)), isNull);
    });
  });
}
