import 'dart:convert';

import 'package:clock/clock.dart';

import '../../domain/factsbook/factsbook_gateway.dart';
import '../../domain/factsbook/factsbook_types.dart';

/// Where the outbox keeps its text between runs.
abstract interface class FactsBookOutboxStore {
  Future<String?> read();
  Future<void> write(String? value);
}

/// An outbox that lives in memory (tests, previews).
class MemoryOutboxStore implements FactsBookOutboxStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? next) async => value = next;
}

/// The phone is full: the newest capture is refused and the text stays where
/// it was typed. The oldest is never dropped (02-contracts 3.10, F105).
class OutboxFullException implements Exception {
  const OutboxFullException();
}

/// One capture waiting on this phone.
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.key,
    required this.request,
    required this.createdAt,
    this.retries = 0,
    this.refused = false,
  });

  final String id;

  /// Its idempotency key: a resend of the same capture is never saved twice.
  final String key;
  final CaptureRequest request;
  final DateTime createdAt;
  final int retries;

  /// The node refused it; it stays until the person decides.
  final bool refused;

  int get bytes => utf8.encode(request.text).length;

  OutboxEntry copyWith({int? retries, bool? refused}) => OutboxEntry(
    id: id,
    key: key,
    request: request,
    createdAt: createdAt,
    retries: retries ?? this.retries,
    refused: refused ?? this.refused,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'key': key,
    'request': request.toJson(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'retries': retries,
    if (refused) 'refused': true,
  };

  static OutboxEntry fromJson(Map<String, Object?> json) => OutboxEntry(
    id: json['id']! as String,
    key: json['key']! as String,
    request: CaptureRequest.fromJson(
      (json['request']! as Map).cast<String, Object?>(),
    ),
    createdAt: DateTime.parse(json['created_at']! as String),
    retries: (json['retries'] as num?)?.toInt() ?? 0,
    refused: json['refused'] == true,
  );

  /// The Not saved yet row for it.
  CouldNotSaveEntry asEntry() => CouldNotSaveEntry(
    id: id,
    text: request.text,
    reason: refused
        ? CouldNotSaveReason.validationRejected
        : CouldNotSaveReason.nodeUnreachable,
    createdAt: createdAt,
    retries: retries,
    state: CouldNotSaveState.kept,
    onPhone: true,
  );
}

/// Captures made while the node could not be reached, held on this phone
/// (D25, D32): bounded to 100 notes and 5 MB; when full the newest is
/// refused and the oldest is never dropped; items stay until sent or
/// discarded by the person.
class FactsBookOutbox {
  FactsBookOutbox(this._store);

  final FactsBookOutboxStore _store;

  static const maxEntries = 100;
  static const maxBytes = 5 * 1024 * 1024;

  final List<OutboxEntry> _entries = [];
  var _loaded = false;
  var _serial = 0;

  List<OutboxEntry> get entries => List.unmodifiable(_entries);

  Future<void> load() async {
    if (_loaded) return;
    final raw = await _store.read();
    if (raw != null) {
      try {
        for (final item in jsonDecode(raw) as List) {
          _entries.add(
            OutboxEntry.fromJson((item as Map).cast<String, Object?>()),
          );
        }
      } on Object {
        // A damaged blob is not a reason to lose what could be read.
      }
    }
    _loaded = true;
  }

  Future<void> _save() => _store.write(
    _entries.isEmpty
        ? null
        : jsonEncode([for (final e in _entries) e.toJson()]),
  );

  /// Keeps [request]; throws [OutboxFullException] when it would not fit.
  Future<OutboxEntry> add(CaptureRequest request, String key) async {
    await load();
    final bytes = utf8.encode(request.text).length;
    final used = _entries.fold<int>(0, (n, e) => n + e.bytes);
    if (_entries.length >= maxEntries || used + bytes > maxBytes) {
      throw const OutboxFullException();
    }
    final entry = OutboxEntry(
      id: 'out_${clock.now().microsecondsSinceEpoch}_${_serial++}',
      key: key,
      request: request,
      createdAt: clock.now(),
    );
    _entries.add(entry);
    await _save();
    return entry;
  }

  Future<void> remove(String id) async {
    await load();
    _entries.removeWhere((e) => e.id == id);
    await _save();
  }

  /// Sends what is waiting (one batch, oldest first). A call that fails to
  /// reach the node rethrows and leaves everything in place. Returns how many
  /// were accepted (or already there).
  Future<int> flush(FactsBookGateway gateway, {String? only}) async {
    await load();
    final batch = [
      for (final e in _entries)
        if (!e.refused && (only == null || e.id == only)) e,
    ].take(maxEntries).toList();
    if (batch.isEmpty) return 0;
    final receipts = await gateway.sendOutbox([
      for (final e in batch)
        OutboxEvent(key: e.key, payload: e.request.toJson()),
    ]);
    var sent = 0;
    for (var position = 0; position < batch.length; position++) {
      final entry = batch[position];
      // Receipts are matched by key; a refusal for an event whose key was
      // not usable comes back with an empty key and is matched by position
      // (the node answers in order).
      OutboxReceipt? receipt;
      for (final r in receipts) {
        if (r.key == entry.key) receipt = r;
      }
      if (receipt == null &&
          receipts.length == batch.length &&
          receipts[position].key.isEmpty) {
        receipt = receipts[position];
      }
      final index = _entries.indexWhere((e) => e.id == entry.id);
      if (index < 0) continue;
      if (receipt == null) {
        _entries[index] = entry.copyWith(retries: entry.retries + 1);
      } else if (receipt.status == OutboxReceiptStatus.refused) {
        _entries[index] = entry.copyWith(
          retries: entry.retries + 1,
          refused: true,
        );
      } else {
        _entries.removeAt(index);
        sent++;
      }
    }
    await _save();
    return sent;
  }
}
