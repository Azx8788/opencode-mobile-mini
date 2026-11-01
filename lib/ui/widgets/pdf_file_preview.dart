import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../../platform/local_pdf.dart';
import '../../platform/platform_capabilities.dart';
import '../app_iconography.dart';
import '../kit/kit_state_view.dart';
import '../kit/kit_viewer.dart';
import 'markdown.dart' show MarkdownInteractionScope;

/// Why a local PDF could not open, in the person's words.
class LocalPdfUnavailable implements Exception {
  const LocalPdfUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The pages of one PDF, rendered on this device through [LocalPdf] for
/// [KitViewerContent.pdf].
///
/// One platform request runs at a time, a page scrolled away before its turn
/// never reaches the platform, and every request in flight is cancelled when
/// the app leaves the foreground (the viewer then offers Try again per page).
class LocalPdfPages with WidgetsBindingObserver {
  LocalPdfPages(this.bytes);

  final Uint8List bytes;

  Future<void> _queue = Future<void>.value();
  final Map<int, String> _requests = {};
  PdfPageImage? _first;
  bool _observing = false;
  bool _disposed = false;

  /// A source for the viewer: loading, then the pages, or the reason it
  /// cannot open (with Try again).
  KitViewerSource source(AppLocalizations l10n) =>
      KitViewerSource.load(() => open(l10n));

  /// Renders page 1 to learn the page count. A device without a PDF
  /// renderer gets "Can't show this file" with the caller's action.
  Future<KitViewerContent> open(AppLocalizations l10n) async {
    if (!platformCapabilities.supportsLocalPdf) {
      return KitViewerContent.binary(
        mimeType: 'application/pdf',
        byteLength: bytes.length,
      );
    }
    final PdfPageImage first;
    try {
      first = _first ?? await _render(0);
    } on PlatformException catch (error) {
      if (error.code == 'unavailable') {
        return KitViewerContent.binary(
          mimeType: 'application/pdf',
          byteLength: bytes.length,
        );
      }
      throw LocalPdfUnavailable(localPdfMessage(l10n, error.code));
    }
    _first = first;
    return KitViewerContent.pdf(
      pageCount: math.min(first.pageCount, LocalPdf.maxPages),
      renderPage: renderPage,
      cancelPage: cancelPage,
    );
  }

  /// One page for the viewer; the platform picks the raster size within its
  /// budget, so [widthPx] is a hint only.
  Future<KitPdfPage> renderPage(int index, int widthPx) async {
    final cached = _first;
    final image = index == 0 && cached != null ? cached : await _render(index);
    return KitPdfPage(
      bytes: image.png,
      width: _pngDimension(image.png, 16),
      height: _pngDimension(image.png, 20),
    );
  }

  /// A page scrolled away before it rendered.
  void cancelPage(int index) {
    final id = _requests.remove(index);
    if (id != null) unawaited(LocalPdf.cancel(id));
    if (_requests.isEmpty) _unobserve();
  }

  /// Cancels every request in flight or waiting.
  void cancelAll() {
    for (final id in _requests.values) {
      unawaited(LocalPdf.cancel(id));
    }
    _requests.clear();
    _unobserve();
  }

  void dispose() {
    _disposed = true;
    cancelAll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) cancelAll();
  }

  Future<PdfPageImage> _render(int page) {
    if (_disposed) {
      return Future.error(PlatformException(code: 'cancelled'));
    }
    final id = LocalPdf.requestID();
    _requests[page] = id;
    _observe();
    final result = Completer<PdfPageImage>();
    _queue = _queue.then((_) async {
      if (_requests[page] != id) {
        result.completeError(PlatformException(code: 'cancelled'));
        return;
      }
      try {
        final image = await LocalPdf.render(bytes, page, id);
        // A page cancelled while the platform was busy never lands late.
        if (_requests[page] != id) {
          throw PlatformException(code: 'cancelled');
        }
        result.complete(image);
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        if (_requests[page] == id) _requests.remove(page);
        if (_requests.isEmpty) _unobserve();
      }
    });
    return result.future;
  }

  void _observe() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void _unobserve() {
    if (!_observing) return;
    _observing = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  static int _pngDimension(Uint8List png, int offset) =>
      png.length < offset + 4 ? 1 : ByteData.sublistView(png).getUint32(offset);
}

/// The person's words for a [LocalPdf] failure code.
String localPdfMessage(AppLocalizations l10n, String code) => switch (code) {
  'encrypted' => l10n.filePdfEncrypted,
  'limit' => l10n.filePdfLimit,
  'unavailable' => l10n.filePdfUnavailable,
  'cancelled' => l10n.filePdfCancelled,
  _ => l10n.filePdfFailed,
};

/// A PDF read on this device, embedded in a host that has its own header:
/// the pages stacked in the kit viewer, with zoom controls, per-page retry
/// and the page caption. An isolated view explains that pages do not render
/// there.
class PdfFilePreview extends StatefulWidget {
  const PdfFilePreview({super.key, required this.bytes, this.name});

  final Uint8List bytes;

  /// The file's name, for the pages' zoom label; defaults to "PDF".
  final String? name;

  @override
  State<PdfFilePreview> createState() => _PdfFilePreviewState();
}

class _PdfFilePreviewState extends State<PdfFilePreview> {
  late LocalPdfPages _pages = LocalPdfPages(widget.bytes);
  KitViewerSource? _source;

  @override
  void didUpdateWidget(PdfFilePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _pages.dispose();
      _pages = LocalPdfPages(widget.bytes);
      _source = null;
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!MarkdownInteractionScope.enabledOf(context)) {
      _pages.cancelAll();
      return Center(
        child: KitStateView(
          icon: AppIconography.file,
          title: l10n.kitViewerCantShow,
          body: l10n.filePreviewPdfIsolated,
          size: KitStateSize.inline,
        ),
      );
    }
    final source = _source ??= _pages.source(l10n);
    return KitViewer(
      name: widget.name ?? 'PDF',
      source: source,
      showHeader: false,
      viewerKey: const ValueKey('file-preview-pdf'),
    );
  }
}
