import 'dart:async';

import 'package:flutter/widgets.dart';

import '../kit/kit_terminal_view.dart';
import 'file_preview.dart';

/// A command and what it printed, drawn the way a terminal would.
///
/// Retired by kit-KitTerminalView: use KitTerminalView.output. This keeps
/// its old signature and forwards to it; a too-long output still opens in
/// the file viewer.
class TerminalView extends StatelessWidget {
  const TerminalView({
    super.key,
    this.command,
    required this.output,
    this.tailLines = 40,
    this.framed = true,
    this.wrap = true,
  });

  final String? command;
  final String output;
  final int tailLines;

  /// Draws its own box. Off where the host already frames the output.
  final bool framed;

  /// Wraps long lines. Off lets the output scroll sideways.
  final bool wrap;

  /// Past this many lines the full output opens in the file viewer.
  static const inlineLineCap = KitTerminalView.inlineLineCap;

  @override
  Widget build(BuildContext context) => KitTerminalView.output(
    output: output,
    command: command,
    tailLines: tailLines,
    framed: framed,
    wrap: wrap,
    onOpenFull: (text) => unawaited(
      showFilePreviewSheet(
        context,
        FilePreviewData(name: 'terminal.txt', text: text),
      ),
    ),
  );
}
