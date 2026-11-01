import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' as xterm;

import '../../l10n/app_localizations.dart';
import '../app_iconography.dart';
import '../widgets/external_link.dart';
import 'kit_buttons.dart';
import 'kit_copy.dart';
import 'kit_sheet.dart';
import 'kit_text.dart';

/// The two things a terminal program can ask of the phone that a plain
/// character grid cannot do: put text on the clipboard (OSC 52) and show a
/// link that wrapped over several rows as one link. Pure functions plus the
/// small sheet a tapped link opens.
abstract final class KitTerminalOsc52 {
  /// The most decoded text one OSC 52 write may put on the clipboard.
  static const maxBytes = 64 * 1024;

  /// The text an OSC 52 set-clipboard asks to copy, or null when the
  /// sequence is not a write we honour. [args] are what follows `52;`
  /// split at `;`: the selection letters, then the base64 payload.
  ///
  /// A `?` payload is a request to READ the clipboard: never answered, so a
  /// program on the other end cannot learn what the person copied. Payloads
  /// that are empty (a clear), not base64, not UTF-8 or past [maxBytes] are
  /// ignored.
  static String? parse(List<String> args) {
    if (args.length < 2) return null;
    final payload = args.sublist(1).join(';').trim();
    if (payload.isEmpty || payload == '?') return null;
    // Base64 is 4/3 the size: refuse before decoding something huge.
    if (payload.length > (maxBytes * 4 ~/ 3) + 8) return null;
    try {
      final bytes = base64.decode(base64.normalize(payload));
      if (bytes.isEmpty || bytes.length > maxBytes) return null;
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }
}

/// Links in the terminal's text.
abstract final class KitTerminalLinks {
  static final _url = RegExp(r'''https?://[^\s<>"'`\x00-\x1f\x7f]+''');

  /// A row that reaches the last column and carries on in the next row is
  /// one line of text. Some programs wrap themselves (a hard newline), some
  /// leave it to the terminal (a soft wrap): both are joined.
  static const _maxRows = 60;

  /// The link under [cell], with the rows it wrapped over joined; null when
  /// the cell is not on a link.
  static String? urlAt(xterm.Terminal terminal, xterm.CellOffset cell) {
    final lines = terminal.buffer.lines;
    if (cell.y < 0 || cell.y >= lines.length) return null;
    final columns = terminal.viewWidth;
    bool full(int y) {
      final line = lines[y];
      if (columns < 1) return false;
      final code = line.getCodePoint(columns - 1);
      return code != 0 && code != 0x20;
    }

    bool continues(int y) {
      // Row y carries on from row y - 1.
      if (y <= 0) return false;
      if (!full(y - 1)) return false;
      if (lines[y].isWrapped) return true;
      final code = lines[y].getCodePoint(0);
      return code != 0 && code != 0x20;
    }

    var first = cell.y;
    while (first > 0 && cell.y - first < _maxRows && continues(first)) {
      first--;
    }
    var last = cell.y;
    while (last + 1 < lines.length &&
        last - cell.y < _maxRows &&
        continues(last + 1)) {
      last++;
    }
    final text = StringBuffer();
    var index = -1;
    for (var y = first; y <= last; y++) {
      final row = lines[y].getText();
      if (y == cell.y) {
        index =
            text.length + cell.x.clamp(0, row.isNotEmpty ? row.length - 1 : 0);
      }
      text.write(row);
    }
    final all = text.toString();
    for (final match in _url.allMatches(all)) {
      if (index < match.start || index >= match.end) continue;
      return _trim(match[0]!);
    }
    return null;
  }

  static String _trim(String url) {
    var end = url.length;
    while (end > 0) {
      final c = url[end - 1];
      if ('.,;:!?\'"]}'.contains(c)) {
        end--;
      } else if (c == ')' &&
          ')'.allMatches(url.substring(0, end)).length >
              '('.allMatches(url.substring(0, end)).length) {
        end--;
      } else {
        break;
      }
    }
    return url.substring(0, end);
  }
}

/// Offers a tapped terminal link: its whole address, then Open link (which
/// goes through [openExternalLink], like every address the app did not
/// write) or Copy link.
Future<void> showKitTerminalLinkSheet(
  BuildContext context,
  String url, {
  Future<bool> Function(Uri uri)? launcher,
  Key? sheetKey,
}) {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  return showKitSheet<void>(
    context,
    title: l10n.terminalLinkTitle,
    sheetKey: sheetKey ?? const ValueKey('terminal-link-sheet'),
    body: (sheetContext) => Directionality(
      textDirection: TextDirection.ltr,
      child: SelectableText(
        url,
        key: const ValueKey('terminal-link-url'),
        style: KitText.styleOf(sheetContext, KitTextRole.mono),
      ),
    ),
    primary: KitAction(
      key: const ValueKey('terminal-link-open'),
      label: l10n.terminalLinkOpen,
      icon: AppIconography.link,
      onPressed: () {
        Navigator.of(context).pop();
        openExternalLink(context, url, launcher: launcher);
      },
    ),
    secondary: KitAction(
      key: const ValueKey('terminal-link-copy'),
      label: l10n.terminalLinkCopy,
      icon: AppIconography.copy,
      onPressed: () {
        Navigator.of(context).pop();
        KitCopy.copy(context, url, redact: false);
      },
    ),
  );
}
