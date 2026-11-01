import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../kit/kit.dart';

/// One entry of a [LocalServerRow]'s overflow menu.
class LocalServerRowMenuItem {
  const LocalServerRowMenuItem({
    required this.keySuffix,
    required this.label,
    required this.onSelected,
  });

  /// Appended to the row's key prefix (`…-disconnect`, `…-recheck`, …).
  final String keySuffix;
  final String label;
  final VoidCallback onSelected;
}

/// A server this app runs on the phone, as one row of the servers list
/// (design standard §6; docs/design/phone-server-screens-cleanup-2026-09-24.md
/// §1): the Servers screen and the server switcher.
///
/// The OpenCode server and the Claude Code daemon keep their own state
/// classes; a person meets both the same way: the agent's own mark (a
/// filled accent tile when it is the server in use), so OpenCode and Claude
/// Code on the same phone are told apart at a glance, the name ("This
/// phone"), one line
/// that says what it runs and where it stands ("OpenCode 2 · Running"), and
/// the menu. Tapping the row does the one likely thing: connect to a
/// running server, start a stopped one, or open the details of the one in
/// use. Restart, Stop (error-coloured, confirmed by the caller) and the
/// host's own entries (Details, Disconnect, Forget) are in the menu, so the
/// list carries no buttons.
///
/// Every key is `<keyPrefix>` or `<keyPrefix>-<part>`: `-connect` is the
/// row while tapping it connects, `-start` the small Start action of a
/// stopped server, `-menu` the menu and `-restart`, `-stop` and each host
/// entry's suffix its items.
class LocalServerRow extends StatelessWidget {
  const LocalServerRow({
    super.key,
    required this.keyPrefix,
    required this.title,
    required this.status,
    required this.connectedLabel,
    required this.stopped,
    required this.locked,
    required this.inProgress,
    required this.connected,
    required this.menuTooltip,
    required this.menuItems,
    required this.startLabel,
    required this.restartLabel,
    required this.stopLabel,
    this.failure,
    this.onStart,
    this.onConnect,
    this.onRestart,
    this.onStop,
    this.onOpen,
    this.running = true,
    this.dividerAbove = false,
    this.mark = AppIconography.phone,
    this.needsYou = false,
    this.fixLabel,
    this.onFix,
    this.connectLabel,
    this.tapOpensPage = false,
  });

  /// The row opens this server's own page on a tap ([onOpen]); connecting
  /// is the menu's named act. Off, a tap connects or starts (the switcher).
  final bool tapOpensPage;

  /// The menu's named connect act ("Connect to This phone").
  final String? connectLabel;

  /// The server waits on the person (no access, not answering): the line
  /// starts with the one "Needs you" span, inline, and wraps whole.
  final bool needsYou;

  /// The one act that fixes what [status] says, named for its target
  /// ("Allow access to Termux"). Tapping the row does the same, unless
  /// [onOpen] is given (a cause that may still let a connect work).
  final String? fixLabel;
  final VoidCallback? onFix;

  /// The agent's own mark: the phone for OpenCode (the phone's own
  /// server), [AppIconography.agent] for Claude Code, so two agents on one
  /// phone never share a glyph.
  final IconData mark;

  /// In a list of rows: the panel's hairline above this one, inset to where
  /// the words start. The row draws it because it alone knows it shows.
  final bool dividerAbove;

  final String keyPrefix;

  /// The server's name: "This phone", "Claude Code on this phone".
  final String title;

  /// What it runs and where it stands: "OpenCode 2 · Running".
  final String status;

  /// The word that leads [status] when this is the server in use.
  final String connectedLabel;

  /// Installed and not running: tapping starts it, and a small Start action
  /// sits at the row's end.
  final bool stopped;

  /// Every control rests (a check or an operation is under way).
  final bool locked;

  /// An operation is running: the leading mark turns into the working mark.
  final bool inProgress;
  final bool connected;

  /// False for a server that is neither running nor stopped (not answering,
  /// no access): Restart and Stop leave the menu and the row opens [onOpen].
  final bool running;
  final String? failure;
  final String menuTooltip;
  final List<LocalServerRowMenuItem> menuItems;
  final String startLabel;
  final String restartLabel;
  final String stopLabel;

  /// Null hides the control (a host that cannot control the server).
  final VoidCallback? onStart;
  final VoidCallback? onConnect;
  final VoidCallback? onRestart;
  final VoidCallback? onStop;

  /// What tapping the row does when it is the server in use, or when it
  /// cannot be connected to: its details.
  final VoidCallback? onOpen;

  ValueKey<String> _key(String part) => ValueKey('$keyPrefix-$part');

  @override
  Widget build(BuildContext context) {
    final failure = this.failure;
    // On the Servers list a tap opens this server's own page, whatever its
    // state; starting and connecting stay named acts (the row's Start, the
    // menu's Connect). The switcher, which exists to switch, taps to connect.
    final VoidCallback? tap;
    final Key? rowKey;
    if (locked) {
      tap = null;
      rowKey = null;
    } else if (onFix != null && onOpen == null) {
      tap = onFix;
      rowKey = null;
    } else if (tapOpensPage) {
      tap = onOpen;
      rowKey = null;
    } else if (stopped) {
      tap = onStart;
      rowKey = null;
    } else if (running && !connected) {
      tap = onConnect;
      rowKey = _key('connect');
    } else {
      tap = onOpen;
      rowKey = null;
    }
    final items = [
      if (tapOpensPage &&
          running &&
          !connected &&
          !stopped &&
          onConnect != null)
        KitMenuItem(
          key: _key('connect'),
          label: connectLabel ?? connectedLabel,
          onSelected: onConnect!,
        ),
      if (running && !stopped && onRestart != null)
        KitMenuItem(
          key: _key('restart'),
          label: restartLabel,
          onSelected: onRestart!,
        ),
      if (running && !stopped && onStop != null)
        KitMenuItem(
          key: _key('stop'),
          label: stopLabel,
          destructive: true,
          onSelected: onStop!,
        ),
      for (final item in menuItems)
        KitMenuItem(
          key: _key(item.keySuffix),
          label: item.label,
          onSelected: item.onSelected,
        ),
    ];
    final Widget? start = stopped && onStart != null
        ? KitButton.tertiary(
            key: _key('start'),
            label: startLabel,
            onPressed: locked ? null : onStart,
          )
        : null;
    // At large text the small Start moves under the row's line (KitRow's
    // `below`), so the name keeps its width.
    final large = MediaQuery.textScalerOf(context).scale(14) > 21;
    final fix = onFix != null && fixLabel != null
        ? KitButton.tertiary(
            key: _key('fix'),
            label: fixLabel!,
            onPressed: locked ? null : onFix,
          )
        : null;
    final below = [
      ?fix,
      if (failure != null)
        // The failure in words, in the failure tone LOOK-5 sets: text1
        // with the error word, never the danger colour, which is kept for
        // acts that lose data.
        KitText(
          failure,
          key: _key('failure'),
          role: KitTextRole.secondary,
          tone: KitTextTone.primary,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      if (start != null && large) KitInset(child: start),
    ];
    final trailing = [
      if (start != null && !large) start,
      if (items.isNotEmpty)
        KitRowMenu(
          key: _key('menu'),
          tooltip: menuTooltip,
          enabled: !locked,
          items: items,
        ),
    ];
    final row = KeyedSubtree(
      key: ValueKey(keyPrefix),
      child: Semantics(
        container: true,
        selected: connected,
        liveRegion: true,
        child: KitRow(
          key: rowKey,
          leading: inProgress
              ? const KitStatusMark(state: KitMarkState.working)
              : KitRowIcon(mark, current: connected),
          title: title,
          titleMaxLines: large ? 2 : 1,
          supporting: TextSpan(
            children: [
              if (connected) kitCurrentSpan(context, connectedLabel),
              if (needsYou) KitNeedsYou.span(context),
              TextSpan(text: status, semanticsLabel: status),
            ],
          ),
          // A cause is read whole: never cut to "…".
          supportingMaxLines: needsYou ? 6 : (large ? 2 : 1),
          supportingKey: _key('runtime'),
          below: below.isEmpty
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: below,
                ),
          onTap: tap,
          // Long-press, right-click and the context-menu key open the same
          // items, which are also the row's semantic actions (KIT-28). The
          // ⋮ stays because the row's tap is taken by its one likely act.
          menu: locked ? const [] : items,
          menuLabel: menuTooltip,
          trailing: trailing.isEmpty
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: trailing),
        ),
      ),
    );
    if (!dividerAbove) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const KitDivider(inset: KitDividerInset.text),
        row,
      ],
    );
  }
}
