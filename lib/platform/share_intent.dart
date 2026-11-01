import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Text shared into the app from another Android app via the system share
/// sheet. The Kotlin side captures `ACTION_SEND` (text/plain) and hands the
/// text over here; [pending] holds it until a connected shell can turn it into
/// a new session. Off Android the class is inert.
class ShareIntent {
  ShareIntent({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('oc/share');

  final MethodChannel _channel;

  /// The most recent shared text that nothing has consumed yet.
  final ValueNotifier<String?> pending = ValueNotifier<String?>(null);

  bool _started = false;
  bool _disposed = false;
  int _acceptGeneration = 0;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Registers for shares delivered while the app is running and drains the
  /// share that may have launched it. Safe to call once; later calls no-op.
  Future<void> start() async {
    if (_started || _disposed || !supported) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (!_disposed && call.method == 'shared') _accept(call.arguments);
      return null;
    });
    final consumeGeneration = _acceptGeneration;
    try {
      final value = await _channel.invokeMethod<String>('consumeSharedText');
      // A live share can arrive while the cold-start consume is in flight.
      // Keep that newer value instead of allowing the stale cold-start value
      // to replace it.
      if (!_disposed && consumeGeneration == _acceptGeneration) {
        _accept(value);
      }
    } on MissingPluginException {
      // Tests and desktop hosts have no channel implementation.
    } on PlatformException {
      // A capture failure must never block startup.
    }
  }

  void _accept(Object? value) {
    if (_disposed) return;
    final text = value is String ? value.trim() : '';
    if (text.isEmpty) return;
    _acceptGeneration++;
    pending.value = text;
  }

  /// Takes the pending text, leaving nothing behind.
  String? take() {
    if (_disposed) return null;
    final text = pending.value;
    pending.value = null;
    return text;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) _channel.setMethodCallHandler(null);
    pending.dispose();
  }
}

/// Text shared out of the app through the system share sheet (Android's
/// chooser, this app itself left out). Off Android it is unsupported and
/// callers hide the action (STATE-13: never a dead button).
abstract final class ShareOut {
  static const MethodChannel _channel = MethodChannel('oc/share');

  static bool get supported => ShareIntent.supported;

  /// Opens the share sheet with [text]; true once it opened. A missing or
  /// failing platform side answers false, never throws.
  static Future<bool> text(
    String text, {
    String? subject,
    @visibleForTesting MethodChannel? channel,
  }) async {
    if (text.isEmpty) return false;
    try {
      final opened = await (channel ?? _channel).invokeMethod<bool>(
        'shareText',
        {'text': text, 'subject': ?subject},
      );
      return opened ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
