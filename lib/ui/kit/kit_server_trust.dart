import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_iconography.dart';
import 'kit_buttons.dart';
import 'kit_sheet.dart';
import 'kit_text.dart';
import 'kit_tokens.dart';

/// A deliberate, server-scoped transport choice. Closing never grants trust.
Future<bool> showKitServerTrust(
  BuildContext context, {
  required String origin,
  String? fingerprintSha256,
  bool privateNetwork = false,
  bool certificateChanged = false,
  DateTime? validFrom,
  DateTime? validTo,
  Key? sheetKey,
}) async {
  final copy = lookupAppLocalizations(Localizations.localeOf(context));
  final certificate = fingerprintSha256 != null;
  return await showKitSheet<bool>(
        context,
        sheetKey: sheetKey ?? const ValueKey('server-trust-sheet'),
        title: certificate
            ? certificateChanged
                  ? copy.serverTrustCertificateChangedTitle
                  : copy.serverTrustCertificateTitle
            : copy.serverTrustHttpTitle,
        icon: AppIconography.warning,
        body: (_) => KitServerTrustBody(
          origin: origin,
          fingerprintSha256: fingerprintSha256,
          privateNetwork: privateNetwork,
          certificateChanged: certificateChanged,
          validFrom: validFrom,
          validTo: validTo,
        ),
        primary: KitAction(
          key: const ValueKey('server-trust-accept'),
          label: certificate
              ? certificateChanged
                    ? copy.serverTrustCertificateReplace
                    : copy.serverTrustCertificateAccept
              : copy.serverTrustHttpAccept,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ) ==
      true;
}

/// The visible warning and fingerprint are the decision itself, so the
/// fingerprint stays expanded, wraps, and remains left-to-right in Arabic.
/// States: none — this immutable warning renders already inspected data.
class KitServerTrustBody extends StatelessWidget {
  const KitServerTrustBody({
    super.key,
    required this.origin,
    this.fingerprintSha256,
    this.privateNetwork = false,
    this.certificateChanged = false,
    this.validFrom,
    this.validTo,
  });

  final String origin;
  final String? fingerprintSha256;
  final bool privateNetwork;
  final bool certificateChanged;
  final DateTime? validFrom;
  final DateTime? validTo;

  @override
  Widget build(BuildContext context) {
    final copy = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    final fingerprint = fingerprintSha256;
    return Padding(
      padding: EdgeInsets.all(tokens.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          KitLtr(
            child: KitText(
              origin,
              role: KitTextRole.headline,
              tone: KitTextTone.primary,
            ),
          ),
          SizedBox(height: tokens.space3),
          if (fingerprint != null && certificateChanged) ...[
            KitText(copy.serverTrustCertificateChangedBody),
            SizedBox(height: tokens.space3),
          ],
          KitText(
            fingerprint != null
                ? copy.serverTrustCertificateBody
                : privateNetwork
                ? copy.addServerCleartextWarning
                : copy.serverTrustHttpPublicBody,
          ),
          if (fingerprint != null) ...[
            SizedBox(height: tokens.space3),
            if (validFrom != null && validTo != null) ...[
              KitText(
                copy.serverTrustCertificateValidity(
                  MaterialLocalizations.of(
                    context,
                  ).formatFullDate(validFrom!.toLocal()),
                  MaterialLocalizations.of(
                    context,
                  ).formatFullDate(validTo!.toLocal()),
                ),
              ),
              SizedBox(height: tokens.space3),
            ],
            KitText(copy.serverTrustFingerprint, role: KitTextRole.label),
            SizedBox(height: tokens.space2),
            KitText.mono(
              fingerprint.toUpperCase().replaceAllMapped(
                RegExp(r'.{2}(?!$)'),
                (match) => '${match[0]}:',
              ),
              key: const ValueKey('server-trust-fingerprint'),
              selectable: true,
            ),
          ],
        ],
      ),
    );
  }
}
