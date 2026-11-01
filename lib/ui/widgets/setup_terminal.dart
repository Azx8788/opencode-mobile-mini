import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../app_iconography.dart';
import '../kit/kit_buttons.dart';
import '../kit/kit_log_panel.dart';

/// A setup step's output (map: embedded-setup-terminal, proposal fix): one
/// [KitLogPanel], mono and left to right in every locale, that follows the
/// newest line until the person scrolls up (then a jump pill counts the new
/// lines), says in words whether the step is still writing or has ended,
/// and has its own Wrap and Copy all in its header (KIT-31).
///
/// Lines are cleaned of terminal control sequences before they are shown;
/// error and warning lines carry the panel's neutral glyphs (never colour
/// alone, LOOK-4, LOOK-5). What the panel copies is the shown text,
/// redacted (SEC-2).
///
/// A host that copies more than the log (a failure report with the phone's
/// diagnostics) names it with [copyTooltip]: that act is the panel's one
/// extra header action, after Copy all, labelled with those words (it
/// reports on this output, so it lives inside the panel, not under it).
/// Without [copyTooltip], the panel's Copy all is the one copy.
///
/// Where the output sits (folded under Details, or the page's content) is
/// the host's call: [expand] fills a host that gives it a bounded height;
/// otherwise it is the folded panel, about twelve lines tall.
///
/// States: empty ("Waiting for Termux output…" while running), live,
/// ended.
class SetupTerminal extends StatefulWidget {
  final String output;
  final bool running;

  /// Retired by shared-phone-1: the panel follows its own scroll (it jumps
  /// to the newest line and offers a jump pill). Kept so hosts compile
  /// (KIT-43); nothing reads it.
  final ScrollController controller;

  /// The host's own copy (see [copyTooltip]).
  final VoidCallback? onCopy;

  /// The words of the host's own copy ("Copy failure report"). Null leaves
  /// copying to the panel's Copy all.
  final String? copyTooltip;
  final bool expand;

  const SetupTerminal({
    super.key,
    required this.output,
    required this.running,
    required this.controller,
    this.onCopy,
    this.copyTooltip,
    this.expand = false,
  });

  // CSI styling/cursor sequences and OSC titles/hyperlinks have no meaning in
  // selectable text. Remove their control bytes, retaining the visible text.
  static final _ansi = RegExp(
    r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B\[[0-?]*[ -/]*[@-~]|\x1B[@-_]',
  );
  static final _error = RegExp(
    r'^(?:(?:npm|bun)\s+)?(?:err!?\b|error\b|fatal\b|failed\b)|^status error\b',
    caseSensitive: false,
  );
  static final _warning = RegExp(
    r'^(?:(?:npm|bun)\s+)?warn(?:ing)?\b|\bretrying\b',
    caseSensitive: false,
  );

  /// The level of one output line: error and warning lines (also behind an
  /// `[oc]` stage prefix) carry the panel's glyph; everything else is plain.
  @visibleForTesting
  static KitLogLevel levelOf(String line) {
    final trimmed = line.trimLeft();
    final message = trimmed.startsWith('[oc]')
        ? trimmed.substring(4).trimLeft()
        : trimmed;
    if (_error.hasMatch(message)) return KitLogLevel.error;
    if (_warning.hasMatch(message)) return KitLogLevel.warning;
    return KitLogLevel.normal;
  }

  /// [output] without terminal control sequences.
  @visibleForTesting
  static String visible(String output) => output.replaceAll(_ansi, '');

  @override
  State<SetupTerminal> createState() => _SetupTerminalState();
}

class _SetupTerminalState extends State<SetupTerminal> {
  final _lines = ValueNotifier<List<KitLogLine>>(const []);

  @override
  void initState() {
    super.initState();
    _read(widget.output);
  }

  @override
  void didUpdateWidget(SetupTerminal old) {
    super.didUpdateWidget(old);
    if (old.output != widget.output) _read(widget.output);
  }

  @override
  void dispose() {
    _lines.dispose();
    super.dispose();
  }

  /// Splits the output into lines, keeping each unchanged line (its
  /// redaction and its arrival time) so a growing log only adds lines.
  void _read(String output) {
    final text = SetupTerminal.visible(output);
    if (text.trim().isEmpty) {
      _lines.value = const [];
      return;
    }
    final raw = text.split('\n');
    // A trailing newline ends the last line; it is not an empty line.
    if (raw.length > 1 && raw.last.isEmpty) raw.removeLast();
    final before = _lines.value;
    final now = clock.now();
    _lines.value = List.unmodifiable([
      for (var i = 0; i < raw.length; i++)
        if (i < before.length && before[i].text == _clean(raw[i]))
          before[i]
        else
          KitLogLine(
            _clean(raw[i]),
            level: SetupTerminal.levelOf(raw[i]),
            at: now,
          ),
    ]);
  }

  static String _clean(String line) =>
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line;

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final hasLines = _lines.value.isNotEmpty;
    final report = widget.copyTooltip;
    final onCopy = widget.onCopy;
    final panel = KitLogPanel(
      lines: _lines,
      title: l10n.setupTerminalTitle,
      live: widget.running,
      ended: widget.running || !hasLines ? null : const KitLogEnd(),
      emptyText: widget.running ? l10n.setupOutputWaiting : null,
      size: widget.expand ? KitLogSize.fill : KitLogSize.folded,
      headerAction: report == null || onCopy == null
          ? null
          : KitAction(
              key: const ValueKey('setup-copy-report'),
              label: report,
              icon: AppIconography.copy,
              onPressed: onCopy,
            ),
    );
    return KeyedSubtree(key: const ValueKey('setup-live-output'), child: panel);
  }
}
