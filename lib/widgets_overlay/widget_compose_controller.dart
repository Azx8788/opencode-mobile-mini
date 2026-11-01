import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ui/kit/kit.dart' show KitSteerBoxPhase;
import 'widget_overlay_api.dart';

/// One plain sentence's worth of outcome; the screen owns the words.
enum WidgetComposeNotice {
  stale,
  unavailable,
  unsupported,
  busy,
  invalid,
  uncertain,
  dictationUnavailable,
}

/// Why the box cannot send right now.
enum WidgetComposeBlock { restart, unknown, uncertain }

/// The floating steer / voice box's state. The draft lives only in
/// [text]: never saved, logged or sent on its own. A second send is refused
/// while one is out, and after an uncertain one the box stays shut so the
/// person checks the conversation first.
class WidgetComposeController extends ChangeNotifier {
  WidgetComposeController({
    required this.api,
    required this.steerMode,
    this.voice = false,
    this.closeDelay = const Duration(milliseconds: 700),
  });

  final WidgetOverlayApi api;
  final String steerMode;
  final bool voice;
  final Duration closeDelay;
  final TextEditingController text = TextEditingController();

  KitSteerBoxPhase phase = KitSteerBoxPhase.ready;
  WidgetComposeNotice? notice;
  bool _uncertain = false;
  bool _disposed = false;
  Timer? _closeTimer;

  WidgetComposeBlock? get block {
    if (_uncertain) return WidgetComposeBlock.uncertain;
    if (voice) return null;
    return switch (steerMode) {
      'steer' || 'afterReply' => null,
      'restart' => WidgetComposeBlock.restart,
      _ => WidgetComposeBlock.unknown,
    };
  }

  void _set(KitSteerBoxPhase next, [WidgetComposeNotice? note]) {
    if (_disposed) return;
    phase = next;
    notice = note;
    notifyListeners();
  }

  Future<void> dictate({String? languageTag}) async {
    if (phase != KitSteerBoxPhase.ready || block != null) return;
    _set(KitSteerBoxPhase.dictating);
    try {
      final heard = (await api.dictate(languageTag: languageTag)).trim();
      if (_disposed) return;
      if (heard.isNotEmpty) {
        final joined = text.text.trim().isEmpty
            ? heard
            : '${text.text.trimRight()} $heard';
        text.value = TextEditingValue(
          text: joined.length > 8000 ? joined.substring(0, 8000) : joined,
          selection: TextSelection.collapsed(
            offset: joined.length > 8000 ? 8000 : joined.length,
          ),
        );
      }
      _set(KitSteerBoxPhase.ready);
    } on PlatformException catch (e) {
      _set(
        KitSteerBoxPhase.ready,
        e.code == 'unavailable'
            ? WidgetComposeNotice.dictationUnavailable
            : null,
      );
    } on Object {
      _set(KitSteerBoxPhase.ready, WidgetComposeNotice.dictationUnavailable);
    }
  }

  Future<void> send(String message) async {
    final body = message.trim();
    if (phase != KitSteerBoxPhase.ready || block != null) return;
    if (body.isEmpty) {
      _set(KitSteerBoxPhase.ready, WidgetComposeNotice.invalid);
      return;
    }
    _set(KitSteerBoxPhase.sending);
    Map<String, dynamic> result;
    try {
      result = await api.submitAction(body);
    } on Object {
      // The call left but its answer did not come back: it may have gone.
      _uncertain = true;
      _set(KitSteerBoxPhase.ready, WidgetComposeNotice.uncertain);
      return;
    }
    if (_disposed) return;
    switch (result['status']) {
      case 'accepted':
        _set(KitSteerBoxPhase.sent);
        _closeTimer = Timer(closeDelay, () {
          if (!_disposed) unawaited(api.close());
        });
      case 'uncertain':
        _uncertain = true;
        _set(KitSteerBoxPhase.ready, WidgetComposeNotice.uncertain);
      default:
        _set(KitSteerBoxPhase.ready, switch (result['error']) {
          'staleRequest' => WidgetComposeNotice.stale,
          'unsupported' => WidgetComposeNotice.unsupported,
          'busy' => WidgetComposeNotice.busy,
          'invalidRequest' => WidgetComposeNotice.invalid,
          'uncertainDelivery' => WidgetComposeNotice.uncertain,
          _ => WidgetComposeNotice.unavailable,
        });
        if (result['error'] == 'uncertainDelivery') _uncertain = true;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _closeTimer?.cancel();
    text.dispose();
    super.dispose();
  }
}
