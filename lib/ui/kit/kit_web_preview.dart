import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../domain/dev_preview.dart';
import '../../l10n/app_localizations.dart';
import '../app_iconography.dart';
import 'kit_buttons.dart';
import 'kit_motion.dart';
import 'kit_state_view.dart';
import 'kit_tokens.dart';

/// What the preview shows at the moment.
enum KitWebPreviewPhase { loading, ready, failed }

/// The handle a screen keeps to a [KitWebPreview]: reload, step back in the
/// page's own history, and the address and state it reports.
class KitWebPreviewController extends ChangeNotifier {
  Future<void> Function()? _reload;
  Future<bool> Function()? _goBack;

  KitWebPreviewPhase _phase = KitWebPreviewPhase.loading;
  KitWebPreviewPhase get phase => _phase;

  Uri? _current;

  /// The address the page is on now (starts as the one it was opened for).
  Uri? get current => _current;

  bool _canGoBack = false;
  bool get canGoBack => _canGoBack;

  Future<void> reload() => _reload?.call() ?? Future<void>.value();

  /// Steps back in the page's history; false when there is none.
  Future<bool> goBack() => _goBack?.call() ?? Future.value(false);

  void _set({KitWebPreviewPhase? phase, Uri? current, bool? canGoBack}) {
    final changed =
        (phase != null && phase != _phase) ||
        (current != null && current != _current) ||
        (canGoBack != null && canGoBack != _canGoBack);
    _phase = phase ?? _phase;
    _current = current ?? _current;
    _canGoBack = canGoBack ?? _canGoBack;
    if (changed) notifyListeners();
  }
}

/// A web page from a dev server, inside the app.
///
/// This is deliberately not a browser. It loads [origin] and nothing else:
///
/// - the page may only navigate within the same host and port; a link to any
///   other address does not load here, it is handed to [onLeave] (which sends
///   it through `openExternalLink`);
/// - no JavaScript channel to the app is ever added, so the page cannot call
///   into it;
/// - cookies, cache and local storage are cleared when the preview opens and
///   again when it closes, and third-party cookies are refused, so nothing
///   from the app's other web content or from a previous preview is shared;
/// - file and content access are off, and the page is denied the camera,
///   microphone and location.
///
/// Where the platform has no web view (desktop), it shows a plain
/// explanation with [KitWebPreview.unsupportedAction].
///
/// States: error.
///
/// While the page loads the screen shows its loading bar from the
/// controller's phase; when nothing answers, this part says so in plain words
/// with Try again (the technical reason is never shown).
class KitWebPreview extends StatefulWidget {
  const KitWebPreview({
    super.key,
    required this.origin,
    required this.controller,
    required this.onLeave,
    this.unsupportedAction,
    this.supported,
  });

  /// The one origin this view may show (host and port are what count).
  final Uri origin;
  final KitWebPreviewController controller;

  /// A navigation to somewhere else, which did not load here.
  final ValueChanged<Uri> onLeave;

  /// Offered when the platform cannot show a web view at all.
  final KitAction? unsupportedAction;

  /// Overrides the platform check (tests).
  final bool? supported;

  static bool platformSupported() =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  State<KitWebPreview> createState() => _KitWebPreviewState();
}

class _KitWebPreviewState extends State<KitWebPreview> {
  WebViewController? _web;
  bool get _supported => widget.supported ?? KitWebPreview.platformSupported();

  @override
  void initState() {
    super.initState();
    if (_supported) unawaited(_start());
  }

  Future<void> _start() async {
    final controller = WebViewController();
    _web = controller;
    final handle = widget.controller;
    handle._current = widget.origin;
    handle._reload = () async {
      handle._set(phase: KitWebPreviewPhase.loading);
      await controller.reload();
    };
    handle._goBack = () async {
      if (!await controller.canGoBack()) return false;
      await controller.goBack();
      return true;
    };
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final target = Uri.tryParse(request.url);
          if (target != null && devPreviewMayLoad(target, widget.origin)) {
            return NavigationDecision.navigate;
          }
          // Only a person's navigation leaves; a sub-frame or a script
          // asking for another address is simply not loaded.
          if (target != null && request.isMainFrame) widget.onLeave(target);
          return NavigationDecision.prevent;
        },
        onPageStarted: (url) {
          handle._set(
            phase: KitWebPreviewPhase.loading,
            current: Uri.tryParse(url),
          );
        },
        onPageFinished: (url) {
          if (handle.phase == KitWebPreviewPhase.failed) return;
          handle._set(phase: KitWebPreviewPhase.ready);
          unawaited(_history());
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame ?? true) {
            handle._set(phase: KitWebPreviewPhase.failed);
          }
        },
        onUrlChange: (change) {
          final url = change.url == null ? null : Uri.tryParse(change.url!);
          if (url != null) handle._set(current: url);
        },
      ),
    );
    await _harden(controller);
    if (!mounted) return;
    setState(() {});
    await controller.loadRequest(widget.origin);
  }

  Future<void> _history() async {
    final web = _web;
    if (web == null) return;
    final back = await web.canGoBack();
    if (mounted) widget.controller._set(canGoBack: back);
  }

  /// Clears what a page could share, and turns off every door the page does
  /// not need. Safe to call repeatedly.
  static Future<void> _clean(WebViewController web) async {
    await web.clearCache();
    await web.clearLocalStorage();
    await WebViewCookieManager().clearCookies();
  }

  Future<void> _harden(WebViewController web) async {
    await _clean(web);
    final platform = web.platform;
    if (platform is AndroidWebViewController) {
      await platform.setAllowFileAccess(false);
      await platform.setAllowContentAccess(false);
      await platform.setGeolocationEnabled(false);
      await AndroidWebViewCookieManager(
        const PlatformWebViewCookieManagerCreationParams(),
      ).setAcceptThirdPartyCookies(platform, false);
    }
  }

  @override
  void dispose() {
    final web = _web;
    widget.controller
      .._reload = null
      .._goBack = null;
    if (web != null) unawaited(_clean(web).catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!_supported) {
      return KitStateView(
        icon: AppIconography.browser,
        title: l10n.devPreviewUnsupportedTitle,
        body: l10n.devPreviewUnsupportedBody,
        primary: widget.unsupportedAction,
      );
    }
    final web = _web;
    final duration = KitMotion.reduced(context)
        ? Duration.zero
        : KitMotion.standard;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final failed = widget.controller.phase == KitWebPreviewPhase.failed;
        return PopScope(
          canPop: !widget.controller.canGoBack,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(widget.controller.goBack());
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (web != null) WebViewWidget(controller: web),
              AnimatedSwitcher(
                duration: duration,
                switchInCurve: KitMotion.enter,
                child: failed
                    ? ColoredBox(
                        key: const ValueKey('kit-web-preview-failed'),
                        color: KitTokens.of(context).roles.ground,
                        child: KitStateView(
                          icon: AppIconography.browser,
                          title: l10n.devPreviewFailedTitle,
                          body: l10n.devPreviewFailedBody(
                            '${widget.origin.port}',
                          ),
                          primary: KitAction(
                            key: const ValueKey('dev-preview-retry'),
                            label: l10n.devPreviewRetry,
                            icon: AppIconography.retry,
                            onPressed: () =>
                                unawaited(widget.controller.reload()),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      },
    );
  }
}
