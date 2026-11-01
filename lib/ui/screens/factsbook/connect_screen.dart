import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_iconography.dart';
import '../../app_theme.dart';
import '../../kit/kit.dart';
import 'factsbook_text.dart';

/// Set up FactsBook (spec 60 section 3): the node's address and the one-time
/// code it printed become a token kept in this phone's secure storage. The
/// address must be on a private network. An optional step names this phone's
/// own approval key (reviewing proposals and changing sharing are signed with
/// it): the key's public half is shown for the node's console, and the owner
/// device id the console returns is entered here.
class FactsBookConnectScreen extends ConsumerStatefulWidget {
  const FactsBookConnectScreen({super.key});

  @override
  ConsumerState<FactsBookConnectScreen> createState() =>
      _FactsBookConnectScreenState();
}

class _FactsBookConnectScreenState
    extends ConsumerState<FactsBookConnectScreen> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  final _owner = TextEditingController();
  bool _working = false;
  Object? _failure;
  String? _ownerKey;

  @override
  void initState() {
    super.initState();
    for (final c in [_address, _code, _owner]) {
      c.addListener(() => setState(() {}));
    }
    unawaited(_loadKey());
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    _owner.dispose();
    super.dispose();
  }

  Future<void> _loadKey() async {
    final key = await ref.read(factsBookSessionProvider).ownerPublicKeyHex();
    if (mounted) setState(() => _ownerKey = key);
  }

  bool get _ready =>
      _address.text.trim().isNotEmpty && _code.text.trim().isNotEmpty;

  Future<void> _connect() async {
    final session = ref.read(factsBookSessionProvider);
    setState(() {
      _working = true;
      _failure = null;
    });
    try {
      await session.pair(
        address: _address.text,
        code: _code.text,
        ownerDeviceId: _owner.text,
      );
      if (mounted) Navigator.of(context).pop();
    } on FactsBookException catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// A refused code reads as "that code did not work", whatever the node
  /// calls it: wrong, used or expired.
  String _words(AppLocalizations l10n, Object failure) {
    if (failure is FactsBookException &&
        (failure.code == 'forbidden_scope' || failure.code == 'unauthorized')) {
      return l10n.fbErrorPairCode;
    }
    return failureWords(l10n, failure);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
    return KitScreen(
      topBar: KitTopBar(title: l10n.fbConnectTitle),
      width: KitScreenWidth.reading,
      loading: _working,
      loadingLabel: l10n.fbConnectTitle,
      body: ListView(
        padding: EdgeInsetsDirectional.only(
          top: tokens.space2,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          Padding(
            padding: rails,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.space4,
              children: [
                KitText(
                  l10n.fbConnectIntro,
                  role: KitTextRole.secondary,
                  tone: KitTextTone.secondary,
                ),
                KitField(
                  fieldKey: const ValueKey('factsbook-connect-address'),
                  controller: _address,
                  kind: KitFieldKind.url,
                  label: l10n.fbConnectAddress,
                  hint: l10n.fbConnectAddressHint,
                ),
                KitField(
                  fieldKey: const ValueKey('factsbook-connect-code'),
                  controller: _code,
                  kind: KitFieldKind.mono,
                  label: l10n.fbConnectCode,
                  helper: l10n.fbConnectCodeHelp,
                ),
                if (_failure != null)
                  KitNotice.error(
                    key: const ValueKey('factsbook-connect-error'),
                    title: l10n.fbConnectFailedTitle,
                    message: _words(l10n, _failure!),
                    details: failureDetails(l10n, _failure),
                  ),
                KitText(
                  l10n.fbConnectOwnerTitle,
                  role: KitTextRole.label,
                  tone: KitTextTone.secondary,
                ),
                KitText(
                  l10n.fbConnectOwnerBody,
                  role: KitTextRole.secondary,
                  tone: KitTextTone.secondary,
                ),
                if (_ownerKey != null && _ownerKey!.isNotEmpty)
                  KitDetailsFold(
                    foldKey: const ValueKey('factsbook-connect-owner-key'),
                    label: l10n.fbConnectOwnerKey,
                    values: [
                      KitTechnicalValue(l10n.fbConnectOwnerKey, _ownerKey!),
                    ],
                  ),
                KitField(
                  fieldKey: const ValueKey('factsbook-connect-owner-id'),
                  controller: _owner,
                  kind: KitFieldKind.mono,
                  label: l10n.fbConnectOwnerId,
                ),
              ],
            ),
          ),
        ],
      ),
      bottom: KitActionBlock(
        primary: KitAction(
          key: const ValueKey('factsbook-connect-button'),
          label: l10n.fbConnectButton,
          icon: AppIconography.link,
          working: _working,
          onPressed: _ready && !_working ? () => unawaited(_connect()) : null,
          disabledReason: _ready ? null : l10n.fbConnectNeeds,
        ),
      ),
    );
  }
}
