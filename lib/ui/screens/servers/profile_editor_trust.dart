part of '../servers_screen.dart';

extension _EditorTrust on _ProfileEditorScreenState {
  String? _pinFor(String url) =>
      cleartextOriginOf(url) == _certificateOrigin ? _certificatePin : null;

  bool _privateHttp(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return isPrivateNetworkHost(host) || ConnectionFailure.isTailnetHost(host);
  }

  Future<void> _confirmCleartext(String url) async {
    final origin = cleartextOriginOf(url);
    if (origin == null) return;
    final allowed = await showKitServerTrust(
      context,
      origin: origin,
      privateNetwork: _privateHttp(url),
    );
    if (!mounted || !allowed || cleartextOriginOf(_url.text) != origin) return;
    _set(() {
      _invalidateProbe();
      _cleartextConfirmed = origin;
    });
    if (_password.isNotEmpty) {
      unawaited(_testConnection());
    } else {
      _scheduleAutoTest();
    }
  }

  bool get _certificateChanged =>
      '${_testResult?.message} ${_submitFailure ?? ''} ${_submitDetails ?? ''}'
          .toLowerCase()
          .contains('certificate changed');

  Widget? _certificateWarning(AppLocalizations copy, KitTokens tokens) {
    if (_isCodex) return null;
    final url = normalizeServerProfileUrl(_url.text);
    if (Uri.tryParse(url)?.scheme != 'https' ||
        validateServerProfileUrl(url) != null) {
      return null;
    }
    final pin = _pinFor(url);
    final failed =
        '${_testResult?.message} ${_submitFailure ?? ''} ${_submitDetails ?? ''}'
            .toLowerCase();
    if (pin == null &&
        !failed.contains('certificate') &&
        !failed.contains('handshake')) {
      return null;
    }
    final changed = _certificateChanged;
    return Padding(
      padding: EdgeInsetsDirectional.only(top: tokens.space2),
      child: KitNotice(
        key: const ValueKey('server-certificate-warning'),
        tone: AppStatusTone.neutral,
        icon: AppIconography.warning,
        message:
            _certificateInspectionFailure ??
            (changed
                ? '${copy.serverTrustCertificateChangedTitle}. ${copy.serverTrustCertificateChangedBody}'
                : pin != null
                ? copy.serverTrustCertificatePinned
                : copy.e7SetupCertificate),
        actions: [
          KitAction(
            key: const ValueKey('server-certificate-inspect'),
            label: pin != null
                ? copy.serverTrustCertificateRecheck
                : copy.serverTrustCertificateInspect,
            onPressed: _submitting || _inspectingCertificate || _testing
                ? null
                : () => _inspectCertificate(url, changed: changed),
          ),
        ],
      ),
    );
  }

  Future<void> _inspectCertificate(String url, {required bool changed}) async {
    final origin = cleartextOriginOf(url);
    if (origin == null || _inspectingCertificate) return;
    final generation = _probeGeneration;
    _set(() {
      _inspectingCertificate = true;
      _certificateInspectionFailure = null;
    });
    try {
      final certificate = await serverCertificateInspector(url);
      if (!mounted ||
          generation != _probeGeneration ||
          cleartextOriginOf(_url.text) != origin) {
        return;
      }
      final replaced =
          changed ||
          (_pinFor(url) != null &&
              _pinFor(url) != certificate.fingerprintSha256);
      final accepted = await showKitServerTrust(
        context,
        origin: origin,
        fingerprintSha256: certificate.fingerprintSha256,
        certificateChanged: replaced,
        validFrom: certificate.startValidity,
        validTo: certificate.endValidity,
      );
      if (!mounted ||
          !accepted ||
          generation != _probeGeneration ||
          cleartextOriginOf(_url.text) != origin) {
        return;
      }
      _set(() {
        _invalidateProbe();
        _certificatePin = certificate.fingerprintSha256;
        _certificateOrigin = origin;
      });
      await _testConnection();
    } catch (_) {
      if (mounted && cleartextOriginOf(_url.text) == origin) {
        _set(
          () => _certificateInspectionFailure = _connectionL10n(
            context,
          ).serverTrustCertificateFailed,
        );
      }
    } finally {
      if (mounted) _set(() => _inspectingCertificate = false);
    }
  }
}
