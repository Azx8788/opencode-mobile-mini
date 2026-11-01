import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Where a Usage section offers its Refresh: the Usage screen has one top
/// bar, and it holds one Refresh for the active tab (owner rule 2026-09-27:
/// an action lives on the bar of the page it acts on, never loose beside a
/// paragraph).
///
/// A section calls [offer] from its build with what Refresh would do now;
/// the Usage screen listens and rebuilds its bar. Listeners hear only real
/// changes (shown, enabled, reason), after the frame, so offering the same
/// thing on every build never loops.
class UsageRefreshSlot extends ChangeNotifier {
  VoidCallback? _onRefresh;
  String? _disabledReason;
  bool _visible = false;
  bool _disposed = false;
  bool _pending = false;

  /// Whether the section has a Refresh at all right now.
  bool get visible => _visible;

  /// Null while Refresh cannot run; [disabledReason] then says why.
  VoidCallback? get onRefresh => _onRefresh;
  String? get disabledReason => _disabledReason;

  void offer({
    required bool visible,
    required VoidCallback? onRefresh,
    String? disabledReason,
  }) {
    final changed =
        visible != _visible ||
        (onRefresh == null) != (_onRefresh == null) ||
        disabledReason != _disabledReason;
    _visible = visible;
    _onRefresh = onRefresh;
    _disabledReason = disabledReason;
    if (!changed || _pending) return;
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!_disposed) notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
