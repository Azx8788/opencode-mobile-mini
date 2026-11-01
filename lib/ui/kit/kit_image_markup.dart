import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../app_iconography.dart';
import 'kit_bidi.dart';
import 'kit_buttons.dart';
import 'kit_icon_button.dart';
import 'kit_notice.dart';
import 'kit_page_route.dart';
import 'kit_screen.dart';
import 'kit_state_view.dart';
import 'kit_status_mark.dart';
import 'kit_tappable.dart';
import '../theme_roles.dart';
import 'kit_tokens.dart';
import 'kit_top_bar.dart';

/// What the editor hands back. [changed] is false when nothing was drawn or
/// cropped, so [bytes] are the original bytes untouched. [send] says the
/// person pressed Send rather than Done.
@immutable
class KitMarkupResult {
  const KitMarkupResult({
    required this.bytes,
    required this.send,
    required this.changed,
  });

  final Uint8List bytes;
  final bool send;
  final bool changed;
}

/// Opens the markup editor for [bytes] full screen. Null when the person
/// leaves with Close.
Future<KitMarkupResult?> showKitImageMarkup(
  BuildContext context, {
  required Uint8List bytes,
  required String name,
  bool canSend = true,
  Key? markupKey,
}) => Navigator.of(context).push<KitMarkupResult>(
  KitPageRoute<KitMarkupResult>(
    fullscreenDialog: true,
    builder: (_) => KitImageMarkup(
      key: markupKey,
      bytes: bytes,
      name: name,
      canSend: canSend,
    ),
  ),
);

/// The largest encoded picture the editor returns (9 MiB, under the 10 MB
/// the composer accepts): a bigger one is scaled down until it fits.
const int kitMarkupMaxBytes = 9 * 1024 * 1024;

/// Pen colours: [MarkupInk], not theme roles.
const _penColours = <_Pen>[
  _Pen(MarkupInk.red, _PenName.red),
  _Pen(MarkupInk.yellow, _PenName.yellow),
  _Pen(MarkupInk.white, _PenName.white),
  _Pen(MarkupInk.black, _PenName.black),
];

enum _PenName { red, yellow, white, black }

class _Pen {
  const _Pen(this.colour, this.name);
  final Color colour;
  final _PenName name;
}

class _Stroke {
  _Stroke(this.colour, this.width, Offset start) : points = [start, start];
  final Color colour;
  final double width;
  final List<Offset> points;
}

/// A picture to draw on and crop (docs/ux-system/kit-api/KitImageMarkup.md):
/// a finger pen in four colours, Undo, Clear and a crop rectangle with
/// corner handles. The result is drawn at the picture's own resolution, not
/// the screen's.
///
/// States: loading, error, working.
///
/// Loading is the picture being read; drawing and cropping are modes of the
/// editor, not states.
class KitImageMarkup extends StatefulWidget {
  const KitImageMarkup({
    super.key,
    required this.bytes,
    required this.name,
    this.canSend = true,
  });

  final Uint8List bytes;
  final String name;

  /// Shows Send beside Done.
  final bool canSend;

  @override
  State<KitImageMarkup> createState() => _KitImageMarkupState();
}

class _KitImageMarkupState extends State<KitImageMarkup> {
  /// How thick the pen looks on screen, in logical px.
  static const double _penDp = 4;
  static const double _minCropDp = 48;
  static const double _handleRoom = 24;

  ui.Image? _image;
  bool _failed = false;
  bool _busy = false;
  final List<_Stroke> _strokes = [];
  _Stroke? _current;
  int? _drawing;
  _Pen _pen = _penColours.first;
  Rect? _crop;
  Rect? _draft;

  Rect get _full =>
      Rect.fromLTWH(0, 0, _image!.width.toDouble(), _image!.height.toDouble());

  bool get _cropping => _draft != null;
  bool get _changed => _strokes.isNotEmpty || _crop != null;

  @override
  void initState() {
    super.initState();
    unawaited(_decode());
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  // --- geometry -----------------------------------------------------------

  /// How the shown rectangle [view] of the picture sits in [box].
  ({double scale, Offset origin}) _fit(Rect view, Size box) {
    final scale = math.min(box.width / view.width, box.height / view.height);
    return (
      scale: scale,
      origin: Offset(
        (box.width - view.width * scale) / 2,
        (box.height - view.height * scale) / 2,
      ),
    );
  }

  // --- pen ----------------------------------------------------------------

  void _down(PointerDownEvent e, Rect view, double scale, Offset origin) {
    if (_drawing != null || _cropping || _busy) return;
    final p = (e.localPosition - origin) / scale + view.topLeft;
    setState(() {
      _drawing = e.pointer;
      _current = _Stroke(_pen.colour, _penDp / scale, p);
      _strokes.add(_current!);
    });
  }

  void _move(PointerMoveEvent e, Rect view, double scale, Offset origin) {
    final stroke = _current;
    if (e.pointer != _drawing || stroke == null) return;
    final p = (e.localPosition - origin) / scale + view.topLeft;
    setState(() => stroke.points.add(p));
  }

  void _up(PointerEvent e) {
    if (e.pointer != _drawing) return;
    setState(() {
      _drawing = null;
      _current = null;
    });
  }

  void _undo() => setState(() {
    if (_strokes.isNotEmpty) _strokes.removeLast();
  });

  void _clear() => setState(() {
    _strokes.clear();
    _crop = null;
  });

  // --- crop ---------------------------------------------------------------

  void _startCrop() => setState(() => _draft = _crop ?? _full);

  void _applyCrop() => setState(() {
    final draft = _draft!;
    _crop = draft == _full ? null : draft;
    _draft = null;
  });

  void _cancelCrop() => setState(() => _draft = null);

  void _dragCorner(int corner, Offset delta, double scale) {
    final rect = _draft!;
    final full = _full;
    final min = _minCropDp / scale;
    final dx = delta.dx / scale;
    final dy = delta.dy / scale;
    var left = rect.left;
    var top = rect.top;
    var right = rect.right;
    var bottom = rect.bottom;
    if (corner == 0 || corner == 2) {
      left = (left + dx).clamp(full.left, right - min);
    } else {
      right = (right + dx).clamp(left + min, full.right);
    }
    if (corner == 0 || corner == 1) {
      top = (top + dy).clamp(full.top, bottom - min);
    } else {
      bottom = (bottom + dy).clamp(top + min, full.bottom);
    }
    setState(() => _draft = Rect.fromLTRB(left, top, right, bottom));
  }

  void _moveCrop(Offset delta, double scale) {
    final rect = _draft!;
    final full = _full;
    final dx = (delta.dx / scale).clamp(
      full.left - rect.left,
      full.right - rect.right,
    );
    final dy = (delta.dy / scale).clamp(
      full.top - rect.top,
      full.bottom - rect.bottom,
    );
    setState(() => _draft = rect.shift(Offset(dx, dy)));
  }

  // --- result -------------------------------------------------------------

  Future<void> _finish({required bool send}) async {
    if (_busy) return;
    if (!_changed) {
      Navigator.of(
        context,
      ).pop(KitMarkupResult(bytes: widget.bytes, send: send, changed: false));
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await _render();
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(KitMarkupResult(bytes: bytes, send: send, changed: true));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
      });
    }
  }

  /// The picture with its marks at its own resolution, as PNG. A result
  /// over [kitMarkupMaxBytes] is scaled down by a quarter at a time.
  Future<Uint8List> _render() async {
    final image = _image!;
    final crop = _crop ?? _full;
    var factor = 1.0;
    while (true) {
      final w = math.max(1, (crop.width * factor).round());
      final h = math.max(1, (crop.height * factor).round());
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.scale(w / crop.width, h / crop.height);
      canvas.translate(-crop.left, -crop.top);
      canvas.drawImage(
        image,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.high,
      );
      _paintStrokes(canvas, _strokes);
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(w, h);
      picture.dispose();
      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      rendered.dispose();
      if (data == null) throw StateError('no png');
      final out = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (out.length <= kitMarkupMaxBytes || factor < 0.2) return out;
      factor *= 0.75;
    }
  }

  // --- build --------------------------------------------------------------

  String _penLabel(AppLocalizations l10n, _PenName name) => switch (name) {
    _PenName.red => l10n.kitMarkupRed,
    _PenName.yellow => l10n.kitMarkupYellow,
    _PenName.white => l10n.kitMarkupWhite,
    _PenName.black => l10n.kitMarkupBlack,
  };

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        // Esc leaves a crop first, then the editor.
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _cropping ? _cancelCrop() : Navigator.of(context).maybePop(),
      },
      child: Focus(autofocus: true, child: _screen(context)),
    );
  }

  Widget _screen(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final cropping = _cropping;
    return KitScreen(
      topBar: KitTopBar(
        title: KitBidi.auto(widget.name),
        subtitle: l10n.kitMarkupTitle,
        exit: KitTopBarExit.close,
      ),
      body: _failed && _image == null
          ? KitStateView(
              icon: AppIconography.imageBroken,
              title: l10n.kitGalleryLoadFailed,
              body: l10n.kitGalleryLoadFailedBody,
            )
          : _image == null
          ? Center(
              child: Semantics(
                label: l10n.kitGalleryLoading,
                child: const KitStatusMark(state: KitMarkState.working),
              ),
            )
          : Padding(
              padding: EdgeInsets.all(tokens.space2),
              child: LayoutBuilder(builder: _canvas),
            ),
      bottom: _image == null
          ? null
          : Padding(
              padding: EdgeInsets.all(tokens.space4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_failed)
                    Padding(
                      padding: EdgeInsets.only(bottom: tokens.space2),
                      child: KitNotice(
                        title: l10n.kitMarkupFailed,
                        message: l10n.kitMarkupFailedBody,
                      ),
                    ),
                  if (!cropping) ...[
                    Semantics(
                      container: true,
                      label: l10n.kitMarkupColours,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final pen in _penColours)
                            _PenSwatch(
                              key: ValueKey('kit-markup-${pen.name.name}'),
                              colour: pen.colour,
                              label: _penLabel(l10n, pen.name),
                              selected: pen == _pen,
                              onTap: () => setState(() => _pen = pen),
                            ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        KitIconButton(
                          key: const ValueKey('kit-markup-undo'),
                          icon: AppIconography.undo,
                          tooltip: l10n.kitMarkupUndo,
                          onPressed: _strokes.isEmpty ? null : _undo,
                        ),
                        KitIconButton(
                          key: const ValueKey('kit-markup-clear'),
                          icon: AppIconography.clearAll,
                          tooltip: l10n.kitMarkupClear,
                          onPressed: _changed ? _clear : null,
                        ),
                        KitIconButton(
                          key: const ValueKey('kit-markup-crop'),
                          icon: AppIconography.crop,
                          tooltip: l10n.kitMarkupCrop,
                          onPressed: _startCrop,
                        ),
                      ],
                    ),
                  ],
                  KitActionBlock(
                    primary: cropping
                        ? KitAction(
                            key: const ValueKey('kit-markup-apply'),
                            label: l10n.kitMarkupApply,
                            icon: AppIconography.check,
                            onPressed: _applyCrop,
                          )
                        : widget.canSend
                        ? KitAction(
                            key: const ValueKey('kit-markup-send'),
                            label: l10n.kitGallerySend,
                            icon: AppIconography.send,
                            working: _busy,
                            onPressed: () => unawaited(_finish(send: true)),
                          )
                        : KitAction(
                            key: const ValueKey('kit-markup-done'),
                            label: l10n.kitMarkupDone,
                            working: _busy,
                            onPressed: () => unawaited(_finish(send: false)),
                          ),
                    secondary: cropping
                        ? KitAction(
                            key: const ValueKey('kit-markup-cancel'),
                            label: l10n.kitMarkupCancel,
                            onPressed: _cancelCrop,
                          )
                        : widget.canSend
                        ? KitAction(
                            key: const ValueKey('kit-markup-done'),
                            label: l10n.kitMarkupDone,
                            onPressed: _busy
                                ? null
                                : () => unawaited(_finish(send: false)),
                          )
                        : null,
                  ),
                ],
              ),
            ),
    );
  }

  Widget _canvas(BuildContext context, BoxConstraints constraints) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final image = _image!;
    final view = _cropping ? _full : (_crop ?? _full);
    final box = constraints.biggest;
    // Room around the picture so a corner handle on its edge stays whole
    // and inside the surface that hit-tests it.
    final room = Size(
      math.max(1, box.width - _handleRoom * 2),
      math.max(1, box.height - _handleRoom * 2),
    );
    final fitted = _fit(view, room);
    final fit = (
      scale: fitted.scale,
      origin: fitted.origin + const Offset(_handleRoom, _handleRoom),
    );
    final size = Size(view.width * fit.scale, view.height * fit.scale);
    final origin = fit.origin;
    final draft = _draft;
    Offset toScreen(Offset p) => (p - view.topLeft) * fit.scale + origin;

    return Semantics(
      container: true,
      image: true,
      label: l10n.kitMarkupCanvas,
      child: Listener(
        key: const ValueKey('kit-markup-canvas'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _down(e, view, fit.scale, origin),
        onPointerMove: (e) => _move(e, view, fit.scale, origin),
        onPointerUp: _up,
        onPointerCancel: _up,
        // The picture's pixels are physical: the handles and crop sit at
        // x from the left whatever the reading direction.
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.fromSize(
            size: box,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _MarkupPainter(
                      image: image,
                      strokes: List.of(_strokes),
                      strokeCount: _strokes.length,
                      pointCount: _current?.points.length ?? 0,
                      view: view,
                      scale: fit.scale,
                      origin: origin,
                      size: size,
                      draft: draft,
                      scrim: tokens.scrim,
                      edge: tokens.roles.accent,
                    ),
                  ),
                ),
                if (draft != null) ...[
                  Positioned.fromRect(
                    rect: Rect.fromPoints(
                      toScreen(draft.topLeft),
                      toScreen(draft.bottomRight),
                    ),
                    child: Semantics(
                      label: l10n.kitMarkupCropArea,
                      child: GestureDetector(
                        key: const ValueKey('kit-markup-crop-area'),
                        behavior: HitTestBehavior.translucent,
                        onPanUpdate: (d) => _moveCrop(d.delta, fit.scale),
                      ),
                    ),
                  ),
                  for (var corner = 0; corner < 4; corner++)
                    _handle(l10n, corner, draft, toScreen, fit.scale),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _handle(
    AppLocalizations l10n,
    int corner,
    Rect draft,
    Offset Function(Offset) toScreen,
    double scale,
  ) {
    final point = switch (corner) {
      0 => draft.topLeft,
      1 => draft.topRight,
      2 => draft.bottomLeft,
      _ => draft.bottomRight,
    };
    final at = toScreen(point);
    const target = 48.0;
    return PositionedDirectional(
      start: at.dx - target / 2,
      top: at.dy - target / 2,
      width: target,
      height: target,
      child: Semantics(
        label: l10n.kitMarkupCropHandle,
        child: GestureDetector(
          key: ValueKey('kit-markup-handle-$corner'),
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => _dragCorner(corner, d.delta, scale),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: KitTokens.of(context).roles.accent,
                shape: BoxShape.circle,
              ),
              child: const SizedBox.square(dimension: 20),
            ),
          ),
        ),
      ),
    );
  }
}

void _paintStrokes(Canvas canvas, List<_Stroke> strokes) {
  for (final stroke in strokes) {
    final paint = Paint()
      ..color = stroke.colour
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = stroke.width
      ..isAntiAlias = true;
    final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (final p in stroke.points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }
}

class _MarkupPainter extends CustomPainter {
  _MarkupPainter({
    required this.image,
    required this.strokes,
    required this.strokeCount,
    required this.pointCount,
    required this.view,
    required this.scale,
    required this.origin,
    required this.size,
    required this.draft,
    required this.scrim,
    required this.edge,
  });

  final ui.Image image;
  final List<_Stroke> strokes;
  final int strokeCount;
  final int pointCount;
  final Rect view;
  final double scale;
  final Offset origin;
  final Size size;
  final Rect? draft;
  final Color scrim;
  final Color edge;

  @override
  void paint(Canvas canvas, Size _) {
    final shown = origin & size;
    canvas.save();
    canvas.clipRect(shown);
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale);
    canvas.translate(-view.left, -view.top);
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
    _paintStrokes(canvas, strokes);
    canvas.restore();
    final crop = draft;
    if (crop != null) {
      final rect = Rect.fromPoints(
        (crop.topLeft - view.topLeft) * scale + origin,
        (crop.bottomRight - view.topLeft) * scale + origin,
      );
      canvas.drawPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect(shown),
          Path()..addRect(rect),
        ),
        Paint()..color = scrim,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = edge
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_MarkupPainter old) =>
      old.image != image ||
      old.strokeCount != strokeCount ||
      old.pointCount != pointCount ||
      old.view != view ||
      old.scale != scale ||
      old.origin != origin ||
      old.draft != draft;
}

/// One pen colour: a 48 dp target around a filled circle, ringed in the
/// accent while it is the pen in use. Named for a screen reader.
class _PenSwatch extends StatelessWidget {
  const _PenSwatch({
    super.key,
    required this.colour,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color colour;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    return KitTappable(
      label: label,
      selected: selected,
      onTap: onTap,
      shape: KitShape.tile,
      child: Center(
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: colour,
            shape: CircleBorder(
              side: BorderSide(
                color: selected ? tokens.roles.accent : tokens.roles.text3,
                width: selected
                    ? KitTokens.focusRingWidth(context)
                    : KitTokens.hairlineWidth(context),
              ),
            ),
          ),
          child: const SizedBox.square(dimension: 28),
        ),
      ),
    );
  }
}
