import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../domain/models.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../kit/kit_text.dart';

/// Read acknowledgement is owned by a visible transcript, never its inventory.
class SessionViewObserver extends StatefulWidget {
  const SessionViewObserver({
    super.key,
    required this.controller,
    required this.sessionID,
    required this.ready,
    required this.child,
  });
  final ConnectionController controller;
  final String sessionID;
  final bool ready;
  final Widget child;

  @override
  State<SessionViewObserver> createState() => _SessionViewObserverState();
}

class _SessionViewObserverState extends State<SessionViewObserver>
    with WidgetsBindingObserver {
  Object? _attempted;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(SessionViewObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _attempted = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _attempted = null;
    _changed();
  }

  bool get _foreground =>
      mounted &&
      widget.ready &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) &&
      ModalRoute.of(context)?.isCurrent == true &&
      TickerMode.valuesOf(context).enabled;

  @override
  Widget build(BuildContext context) {
    // Establish dependencies so route coverage/reveal changes trigger a build.
    final currentRoute = ModalRoute.isCurrentOf(context) == true;
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final controller = widget.controller;
    final sessionID = widget.sessionID;
    bool foreground() =>
        _foreground &&
        widget.sessionID == sessionID &&
        identical(widget.controller, controller);
    final locationRevision = controller.locationRevision;
    final idle = controller.sessionsById[widget.sessionID]?.time?.idle;
    if (!currentRoute ||
        !tickerEnabled ||
        !_foreground ||
        controller.busySessions.contains(widget.sessionID)) {
      _attempted = null;
    } else if (controller.supportsSessionReadState &&
        idle != null &&
        idle > 0) {
      final key = (
        controller.locationRevision,
        controller.connectionRevision,
        controller.readPrivacyRevision,
        widget.sessionID,
        idle,
      );
      if (_attempted != key && !_scheduled) {
        _scheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduled = false;
          if (!foreground()) return;
          _attempted = key;
          unawaited(
            controller
                .viewSession(
                  sessionID,
                  isForeground: foreground,
                  observedIdle: idle,
                  expectedLocationRevision: locationRevision,
                )
                .catchError((Object _) {
                  // Read receipts are best effort. Local state survives; retry on
                  // reopen, foreground resume or transport recovery, without a toast
                  // on every server outage or any background retry queue.
                }),
          );
        });
      }
    }
    return widget.child;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Text provides both a visible and spoken status, independent of color
/// (kit only, shared-shell-1: a [KitText] in the label role).
class SessionUnreadBadge extends StatelessWidget {
  const SessionUnreadBadge({
    super.key,
    required this.controller,
    required this.session,
  });
  final ConnectionController controller;
  final Session session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.isSessionUnread(session)) return const SizedBox.shrink();
      final l10n =
          Localizations.of<AppLocalizations>(context, AppLocalizations) ??
          lookupAppLocalizations(Localizations.localeOf(context));
      // The word carries the state (STATE-9), in the label role; no
      // accent (LOOK-6: accent is not a status colour).
      return KitText(
        l10n.sessionUnread,
        key: ValueKey('session-unread-${session.id}'),
        role: KitTextRole.label,
      );
    },
  );
}
