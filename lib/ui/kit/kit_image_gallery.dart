import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../app_iconography.dart';
import 'kit_bidi.dart';
import 'kit_buttons.dart';
import 'kit_image.dart';
import 'kit_image_markup.dart';
import 'kit_motion.dart';
import 'kit_page_route.dart';
import 'kit_screen.dart';
import 'kit_state_view.dart';
import 'kit_status_mark.dart';
import 'kit_tokens.dart';
import 'kit_top_bar.dart';

/// One picture of a [KitImageGallery]. [load] is called lazily, only for the
/// picture shown and its neighbours, and again after "Try again".
@immutable
class KitGalleryPicture {
  const KitGalleryPicture({
    required this.id,
    required this.name,
    required this.load,
  });

  /// Stable within one gallery; an edit is remembered under it.
  final String id;

  /// The file's name, as written.
  final String name;

  /// The picture's bytes, or null when it cannot be read.
  final Future<Uint8List?> Function() load;
}

/// Puts a picture in the host's message field. [edited] says the bytes are
/// the person's markup (a PNG named `…-edited.png`). Returns true when the
/// picture was added, which closes the gallery; false keeps it open (the
/// host has already said why).
typedef KitGallerySend =
    Future<bool> Function(Uint8List bytes, String name, {required bool edited});

/// Opens [pictures] as a full-screen gallery on [initialIndex].
Future<void> showKitImageGallery(
  BuildContext context, {
  required List<KitGalleryPicture> pictures,
  int initialIndex = 0,
  KitGallerySend? onSend,
  Key? galleryKey,
}) => Navigator.of(context).push<void>(
  KitPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => KitImageGallery(
      key: galleryKey,
      pictures: pictures,
      initialIndex: initialIndex,
      onSend: onSend,
    ),
  ),
);

/// The pictures of a conversation, one swipe apart, in the order they were
/// shown (docs/ux-system/kit-api/KitImageGallery.md). Each picture pinches
/// and pans like [KitZoom]; a swipe changes picture only while the shown one
/// is not zoomed in. Edit opens [showKitImageMarkup]; Send hands the
/// (edited) picture to [onSend] and closes.
///
/// States: loading, error, disabled, working.
///
/// Loading and error are per picture; disabled is Edit and Send before the
/// picture has loaded; working is Send in flight.
class KitImageGallery extends StatefulWidget {
  const KitImageGallery({
    super.key,
    required this.pictures,
    this.initialIndex = 0,
    this.onSend,
  }) : assert(pictures.length > 0, 'KitImageGallery needs a picture');

  final List<KitGalleryPicture> pictures;
  final int initialIndex;

  /// Null hides Send (the agent cannot take pictures).
  final KitGallerySend? onSend;

  @override
  State<KitImageGallery> createState() => _KitImageGalleryState();
}

class _KitImageGalleryState extends State<KitImageGallery> {
  late final PageController _pages;
  late int _index;
  final Map<int, Future<Uint8List?>> _loads = {};
  final Map<String, Uint8List> _edited = {};
  final Set<String> _readable = {};
  final Set<int> _zoomed = {};
  final Set<int> _pointers = {};
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.pictures.length - 1);
    _pages = PageController(initialPage: _index);
    _prefetch(_index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<Uint8List?> _future(int i) => _loads.putIfAbsent(i, () async {
    Uint8List? bytes;
    try {
      bytes = await widget.pictures[i].load();
    } catch (_) {
      bytes = null;
    }
    if (bytes != null && bytes.isNotEmpty && mounted) {
      setState(() => _readable.add(widget.pictures[i].id));
    }
    return bytes;
  });

  /// Reads the shown picture and the two beside it, no others.
  void _prefetch(int i) {
    for (final n in [i - 1, i, i + 1]) {
      if (n >= 0 && n < widget.pictures.length) unawaited(_future(n));
    }
  }

  bool get _locked => _zoomed.contains(_index) || _pointers.length > 1;

  void _onZoom(int i, bool zoomed) {
    if (zoomed == _zoomed.contains(i)) return;
    setState(() => zoomed ? _zoomed.add(i) : _zoomed.remove(i));
  }

  void _pointerDown(PointerDownEvent e) {
    if (_pointers.add(e.pointer) && _pointers.length == 2) setState(() {});
  }

  void _pointerUp(PointerEvent e) {
    if (_pointers.remove(e.pointer) && _pointers.length == 1) setState(() {});
  }

  void _retry(int i) => setState(() {
    _loads.remove(i);
  });

  static String _editedName(String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return '$stem-edited.png';
  }

  Future<void> _edit() async {
    final picture = widget.pictures[_index];
    final original = _edited[picture.id] ?? await _future(_index);
    if (original == null || !mounted) return;
    final result = await showKitImageMarkup(
      context,
      bytes: original,
      name: picture.name,
      canSend: widget.onSend != null,
    );
    if (result == null || !mounted) return;
    if (result.changed) setState(() => _edited[picture.id] = result.bytes);
    if (result.send) await _send();
  }

  Future<void> _send() async {
    final onSend = widget.onSend;
    if (onSend == null || _sending) return;
    final picture = widget.pictures[_index];
    final edited = _edited[picture.id];
    final bytes = edited ?? await _future(_index);
    if (bytes == null || !mounted) return;
    setState(() => _sending = true);
    var added = false;
    try {
      added = await onSend(
        bytes,
        edited == null ? picture.name : _editedName(picture.name),
        edited: edited != null,
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    if (added && mounted) Navigator.of(context).pop();
  }

  /// Arrow keys on a PC: the picture on that side of the screen. A zoomed
  /// picture keeps the arrows for panning (KitZoom takes them first).
  void _step(bool towardsEnd) {
    if (_zoomed.contains(_index) || !_pages.hasClients) return;
    final to = _index + (towardsEnd ? 1 : -1);
    if (to < 0 || to >= widget.pictures.length) return;
    unawaited(
      _pages.animateToPage(
        to,
        duration: KitMotion.reduced(context)
            ? Duration.zero
            : KitMotion.standard,
        curve: KitMotion.enter,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(rtl),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(!rtl),
      },
      child: Focus(autofocus: true, child: _screen(context)),
    );
  }

  Widget _screen(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final total = widget.pictures.length;
    final picture = widget.pictures[_index];
    final ready =
        _readable.contains(picture.id) || _edited.containsKey(picture.id);
    return KitScreen(
      topBar: KitTopBar(
        title: KitBidi.auto(picture.name),
        subtitle: total > 1 ? l10n.kitGalleryPosition(_index + 1, total) : null,
        exit: KitTopBarExit.close,
        actions: [
          KitAction(
            key: const ValueKey('kit-gallery-edit'),
            label: l10n.kitGalleryEdit,
            icon: AppIconography.edit,
            onPressed: !ready ? null : () => unawaited(_edit()),
          ),
        ],
      ),
      body: Listener(
        onPointerDown: _pointerDown,
        onPointerUp: _pointerUp,
        onPointerCancel: _pointerUp,
        child: Semantics(
          container: true,
          label: l10n.kitGalleryPictureLabel(_index + 1, total, picture.name),
          child: PageView.builder(
            key: const ValueKey('kit-gallery-pager'),
            controller: _pages,
            physics: _locked
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemCount: total,
            onPageChanged: (i) {
              setState(() => _index = i);
              _prefetch(i);
            },
            itemBuilder: (context, i) {
              final item = widget.pictures[i];
              return _GalleryPage(
                key: ValueKey('kit-gallery-page-${item.id}'),
                picture: item,
                load: _future(i),
                edited: _edited[item.id],
                onZoom: (zoomed) => _onZoom(i, zoomed),
                onRetry: () => _retry(i),
              );
            },
          ),
        ),
      ),
      bottom: widget.onSend == null
          ? null
          : Padding(
              padding: EdgeInsets.all(tokens.space4),
              child: KitActionBlock(
                primary: KitAction(
                  key: const ValueKey('kit-gallery-send'),
                  label: l10n.kitGallerySend,
                  icon: AppIconography.send,
                  working: _sending,
                  onPressed: !ready ? null : () => unawaited(_send()),
                ),
              ),
            ),
    );
  }
}

class _GalleryPage extends StatefulWidget {
  const _GalleryPage({
    super.key,
    required this.picture,
    required this.load,
    required this.edited,
    required this.onZoom,
    required this.onRetry,
  });

  final KitGalleryPicture picture;
  final Future<Uint8List?> load;
  final Uint8List? edited;
  final ValueChanged<bool> onZoom;
  final VoidCallback onRetry;

  @override
  State<_GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<_GalleryPage> {
  final KitZoomController _zoom = KitZoomController();

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_changed);
  }

  @override
  void dispose() {
    _zoom.removeListener(_changed);
    _zoom.dispose();
    super.dispose();
  }

  void _changed() {
    final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.01;
    // Told after the frame: the transform changes during a gesture.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onZoom(zoomed);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final edited = widget.edited;
    if (edited != null) return _picture(edited);
    return FutureBuilder<Uint8List?>(
      future: widget.load,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: Semantics(
              label: l10n.kitGalleryLoading,
              child: const KitStatusMark(state: KitMarkState.working),
            ),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return KitStateView(
            icon: AppIconography.imageBroken,
            title: l10n.kitGalleryLoadFailed,
            body: l10n.kitGalleryLoadFailedBody,
            primary: KitAction(
              label: l10n.kitGalleryTryAgain,
              icon: AppIconography.retry,
              onPressed: widget.onRetry,
            ),
          );
        }
        return _picture(bytes);
      },
    );
  }

  Widget _picture(Uint8List bytes) => KitZoom(
    label: widget.picture.name,
    controller: _zoom,
    resetKey: widget.picture.id,
    child: Center(
      child: KitImage(
        source: KitImageSource.memory(bytes),
        semanticsLabel: widget.picture.name,
        imageKey: const ValueKey('kit-gallery-image'),
      ),
    ),
  );
}
