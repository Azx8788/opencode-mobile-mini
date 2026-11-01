import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../app_iconography.dart';
import '../kit/kit_dialog.dart';
import '../kit/kit_surface.dart';
import '../kit/kit_text.dart';
import '../kit/kit_tokens.dart';
import 'desktop_interaction.dart';

/// A file the window manager handed the app through a drag-and-drop.
///
/// Deliberately not the plugin's own type: the composer's drop handler is
/// then plain Dart that a widget test can drive without a platform channel.
class DroppedFile {
  const DroppedFile({
    required this.name,
    required this.mimeType,
    required this.length,
    required this.readBytes,
  });

  final String name;
  final String? mimeType;

  /// Consulted before [readBytes], so an oversized file is refused without
  /// ever being pulled into memory.
  final Future<int> Function() length;
  final Future<Uint8List> Function() readBytes;
}

typedef DroppedFileHandler = Future<void> Function(List<DroppedFile> files);

/// Accepts files dropped onto [child] on desktop.
///
/// Off desktop this returns [child] untouched — no plugin, no listener, no
/// extra widget in the Android tree.
class DesktopFileDropTarget extends StatefulWidget {
  const DesktopFileDropTarget({
    super.key,
    required this.onDrop,
    required this.child,
  });

  final DroppedFileHandler onDrop;
  final Widget child;

  @override
  DesktopFileDropTargetState createState() => DesktopFileDropTargetState();
}

class DesktopFileDropTargetState extends State<DesktopFileDropTarget> {
  bool _dragging = false;
  bool _handlingDrop = false;

  /// Runs the drop handler as though the window manager had delivered
  /// [files]. Lets a widget test exercise the real attachment pipeline
  /// without a platform channel.
  @visibleForTesting
  Future<void> debugHandleDrop(List<DroppedFile> files) => _handle(files);

  Future<void> _handle(List<DroppedFile> files) async {
    if (mounted) setState(() => _dragging = false);
    if (!mounted || files.isEmpty || _handlingDrop) return;
    _handlingDrop = true;
    try {
      await widget.onDrop(files);
    } catch (_) {
      if (!mounted) return;
      // Never display exception text: it can contain local paths or server
      // content. Do not retry automatically; some files may already be added.
      final l10n = lookupAppLocalizations(Localizations.localeOf(context));
      await showKitAlert(
        context,
        title: l10n.desktopDropFailedTitle,
        body: l10n.desktopDropFailedRecovery,
        icon: AppIconography.attach,
        alertKey: const ValueKey('desktop-drop-failed'),
      );
    } finally {
      _handlingDrop = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopInteractions) return widget.child;
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) => unawaited(
        _handle([
          for (final item in details.files)
            DroppedFile(
              name: item.name,
              mimeType: item.mimeType,
              length: item.length,
              readBytes: item.readAsBytes,
            ),
        ]),
      ),
      child: Stack(
        children: [
          widget.child,
          if (_dragging)
            PositionedDirectional(
              start: 0,
              end: 0,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                // A solid surface step over the composer, never a tint or a
                // blur (LOOK-20, LOOK-22), with its hairline edge.
                child: KitSurface(
                  key: const ValueKey('composer-drop-highlight'),
                  level: KitSurfaceLevel.surface3,
                  shape: KitShape.panel,
                  outlined: true,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        KitSurface.tile(AppIconography.attach),
                        SizedBox(width: tokens.space3),
                        Flexible(
                          child: KitText(
                            l10n.desktopDropHint,
                            role: KitTextRole.label,
                            maxLines: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
