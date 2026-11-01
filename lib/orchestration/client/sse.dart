/// SSE consumer for orchestration event streams: `Last-Event-ID` resume,
/// heartbeat liveness, exponential backoff with jitter, head-only replay
/// detection.
///
/// Modelled on `lib/api2/sse2.dart`, whose incremental [Sse2Parser] is
/// reused as is (its `id:` / `event:` / `data:` contract is exactly what
/// Gas City emits). Nothing else from `lib/api2` is imported.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken, Response, ResponseBody;

import '../../api2/sse2.dart' show Sse2Frame, Sse2Parser;
import '../adapters/gascity/dto/event.dart';
import '../adapters/gascity/dto/json_read.dart';
import '../events/cursor.dart';
import 'http.dart';

/// Connection lifecycle of one [OrchestrationSseClient].
enum OrchestrationStreamStatus {
  /// First connection attempt in flight.
  connecting,

  /// Connected; frames or heartbeats are arriving.
  live,

  /// Lost the connection; a retry is scheduled or in flight.
  reconnecting,

  /// [OrchestrationSseClient.close] was called; nothing more will arrive.
  closed,
}

/// The provider resumed from its head instead of the requested cursor.
class HeadOnlyReplay {
  const HeadOnlyReplay({required this.requestedSeq, required this.firstSeq});

  /// The `seq` the client asked to resume after (`Last-Event-ID`).
  final int requestedSeq;

  /// The `seq` of the first frame the provider actually sent.
  final int firstSeq;

  @override
  String toString() => 'HeadOnlyReplay(after $requestedSeq, got $firstSeq)';
}

/// Backoff schedule: `base * 2^attempt`, capped at [cap], multiplied by a
/// jitter factor in `[0.5, 1.5)` and capped again. Pure, so tests can
/// check it.
Duration backoffDelay(
  int attempt, {
  Duration base = const Duration(milliseconds: 500),
  Duration cap = const Duration(seconds: 30),
  Random? random,
}) {
  final exponent = attempt.clamp(0, 16);
  var ms = base.inMilliseconds * (1 << exponent);
  if (ms > cap.inMilliseconds) ms = cap.inMilliseconds;
  final jitter = 0.5 + (random ?? Random()).nextDouble();
  ms = (ms * jitter).round();
  if (ms > cap.inMilliseconds) ms = cap.inMilliseconds;
  return Duration(milliseconds: ms);
}

/// Opens an SSE endpoint through an [OrchestrationHttpClient] and delivers
/// every frame as a [GcStreamFrame] on [frames]. The client owns reconnect:
/// after a drop it waits [backoffDelay] and reopens with `Last-Event-ID`
/// set to the last id it saw, so the provider resumes after it. Frames at
/// or below the cursor are dropped as duplicates.
///
/// Liveness: `event: heartbeat` frames (and any other frame) mark the
/// stream live; [stallTimeout] of silence between chunks is treated as a
/// dead connection and triggers a reconnect. Heartbeats are forwarded so
/// the caller's own stall timer sees them.
///
/// Head-only replay: when the first id-bearing frame after a (re)connect
/// with a known cursor is not `cursor + 1`, the provider did not resume
/// where asked (its ring buffer moved on, or it restarted); the client
/// adopts the provider's numbering and emits a [HeadOnlyReplay] on
/// [headOnlyReplay] so the controller can mark every scope dirty.
///
/// [frames] is single-subscription: listening starts the connection and
/// cancelling closes the client. [status] and [headOnlyReplay] are
/// broadcast.
class OrchestrationSseClient {
  OrchestrationSseClient({
    required this.http,
    required this.path,
    EventCursor resumeFrom = EventCursor.none,
    Map<String, Object?> query = const {},
    this.stallTimeout = const Duration(seconds: 90),
    this.backoffBase = const Duration(milliseconds: 500),
    this.backoffCap = const Duration(seconds: 30),
    this.backoffResetAfter = const Duration(seconds: 30),
    this.stopOnNotFound = false,
    Random? random,
  }) : _cursor = resumeFrom,
       _query = Map.unmodifiable(query),
       _random = random ?? Random() {
    _frames = StreamController<GcStreamFrame>(onListen: start, onCancel: close);
  }

  final OrchestrationHttpClient http;

  /// Host-relative stream path (`/v0/city/<city>/events/stream`).
  final String path;

  /// Silence between chunks after which the connection is deemed dead.
  final Duration stallTimeout;
  final Duration backoffBase;
  final Duration backoffCap;

  /// A connection that stays up this long resets the backoff attempt.
  final Duration backoffResetAfter;

  /// When set, a 404 on connect is final: the exception is delivered on
  /// [frames], the client closes and nothing is retried. Session streams
  /// use it, since a session that is gone never comes back.
  final bool stopOnNotFound;

  final Map<String, Object?> _query;
  final Random _random;
  late final StreamController<GcStreamFrame> _frames;
  final _status = StreamController<OrchestrationStreamStatus>.broadcast();
  final _headOnly = StreamController<HeadOnlyReplay>.broadcast();

  EventCursor _cursor;
  OrchestrationStreamStatus _currentStatus = OrchestrationStreamStatus.closed;
  DateTime? _lastLiveAt;
  int _attempt = 0;
  int _generation = 0;
  int _connections = 0;
  bool _started = false;
  bool _closed = false;
  Timer? _retryTimer;
  CancelToken? _cancelToken;

  /// Decoded frames, in order, duplicates removed.
  Stream<GcStreamFrame> get frames => _frames.stream;

  /// Lifecycle transitions; [currentStatus] holds the latest.
  Stream<OrchestrationStreamStatus> get status => _status.stream;
  OrchestrationStreamStatus get currentStatus => _currentStatus;

  /// Emitted once per connection that resumed from the wrong place.
  Stream<HeadOnlyReplay> get headOnlyReplay => _headOnly.stream;

  /// Resume position: advanced by every id-bearing frame.
  EventCursor get cursor => _cursor;

  /// When the last chunk arrived (frame or heartbeat); null before the
  /// first.
  DateTime? get lastLiveAt => _lastLiveAt;

  /// Connections opened so far (1 after the first successful connect).
  int get connectionCount => _connections;
  bool get isClosed => _closed;

  /// Opens the stream. Idempotent; listening to [frames] calls it.
  void start() {
    if (_closed || _started) return;
    _started = true;
    _connect();
  }

  /// Closes the connection and every stream. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation += 1;
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelToken?.cancel('stream closed');
    _cancelToken = null;
    _setStatus(OrchestrationStreamStatus.closed);
    await _status.close();
    await _headOnly.close();
    if (!_frames.isClosed) await _frames.close();
  }

  void _setStatus(OrchestrationStreamStatus next) {
    if (_currentStatus == next) return;
    _currentStatus = next;
    if (!_status.isClosed) _status.add(next);
  }

  void _connect() {
    if (_closed) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    final generation = ++_generation;
    _setStatus(
      _attempt == 0 && _connections == 0
          ? OrchestrationStreamStatus.connecting
          : OrchestrationStreamStatus.reconnecting,
    );
    unawaited(
      _pump(generation).whenComplete(() {
        if (!_isCurrent(generation)) return;
        _attempt += 1;
        _setStatus(OrchestrationStreamStatus.reconnecting);
        final delay = backoffDelay(
          _attempt - 1,
          base: backoffBase,
          cap: backoffCap,
          random: _random,
        );
        _retryTimer = Timer(delay, () {
          _retryTimer = null;
          if (_isCurrent(generation)) _connect();
        });
      }),
    );
  }

  Future<void> _pump(int generation) async {
    Timer? resetTimer;
    StreamSubscription<Uint8List>? subscription;
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    final requested = _cursor;
    try {
      final Response<ResponseBody> response = await http.openStream(
        path,
        query: _query,
        headers: requested.resumeHeaders(),
        receiveTimeout: stallTimeout,
        cancelToken: cancelToken,
      );
      if (!_isCurrent(generation)) return;
      _connections += 1;
      _setStatus(OrchestrationStreamStatus.live);
      _lastLiveAt = DateTime.now();
      resetTimer = Timer(backoffResetAfter, () {
        if (_isCurrent(generation)) _attempt = 0;
      });

      final done = Completer<void>();
      var firstIdSeen = false;
      final parser = Sse2Parser((frame) {
        if (!_isCurrent(generation)) return;
        final decoded = _decode(frame);
        if (decoded == null) return;
        final seq = decoded.seq;
        if (seq != null) {
          if (!firstIdSeen) {
            firstIdSeen = true;
            final expected = requested.seq;
            if (expected != null && seq != expected + 1) {
              // The provider did not resume where asked: adopt its
              // numbering so nothing it sends now is dropped, and tell the
              // caller everything may have changed meanwhile.
              _cursor = EventCursor(seq: seq - 1);
              if (!_headOnly.isClosed) {
                _headOnly.add(
                  HeadOnlyReplay(requestedSeq: expected, firstSeq: seq),
                );
              }
            }
          }
          final current = _cursor.seq;
          if (current != null && seq <= current) return; // duplicate
          _cursor = _cursor.advance(seq, eventId: decoded.id);
        } else if (decoded.id != null && !decoded.isHeartbeat) {
          _cursor = _cursor.advance(null, eventId: decoded.id);
        }
        if (!_frames.isClosed) _frames.add(decoded);
      });

      subscription = response.data!.stream.cast<Uint8List>().listen(
        (chunk) {
          if (!_isCurrent(generation)) return;
          _lastLiveAt = DateTime.now();
          parser.add(chunk);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!done.isCompleted) done.completeError(error, stackTrace);
        },
        onDone: () {
          parser.flush();
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future;
    } on OrchestrationHttpException catch (error) {
      if (stopOnNotFound && error.isNotFound && _isCurrent(generation)) {
        if (!_frames.isClosed) _frames.addError(error);
        unawaited(close());
      }
      // Any other HTTP failure ends this attempt; the caller schedules the
      // next one.
    } on Object {
      // Any failure (refused, timed out, dropped mid-stream) ends this
      // attempt; the caller schedules the next one.
    } finally {
      resetTimer?.cancel();
      await subscription?.cancel();
      if (!cancelToken.isCancelled) cancelToken.cancel('stream pump finished');
      if (_isCurrent(generation)) _cancelToken = null;
    }
  }

  bool _isCurrent(int generation) => !_closed && generation == _generation;

  /// [Sse2Frame] → [GcStreamFrame]; malformed data is skipped.
  static GcStreamFrame? _decode(Sse2Frame frame) {
    Object? decoded;
    try {
      decoded = jsonDecode(frame.data);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final data = readMap(decoded);
    final event =
        frame.event ??
        (data.length == 1 && data.containsKey('timestamp')
            ? 'heartbeat'
            : data.containsKey('type')
            ? 'event'
            : 'message');
    return GcStreamFrame(
      event: event,
      id: frame.id,
      data: data,
      raw: {if (frame.id != null) 'id': frame.id, 'event': event, 'data': data},
    );
  }
}
