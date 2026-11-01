import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../builtin/builtin_linux.dart';
import '../../domain/termux_migration_service.dart';
import '../../l10n/app_localizations.dart';
import '../../platform/platform_capabilities.dart';
import '../../state/connection.dart';
import '../../state/profiles.dart';
import '../../state/termux_migration_owner.dart';
import '../app_iconography.dart';
import '../kit/kit.dart';
import '../screens/termux_migration_screen.dart';

/// Whether [profile] is a Termux server this phone can move to the in-app
/// server (the managed Ubuntu in Termux, on a phone that runs the in-app
/// Linux).
bool offersTermuxMigration(ServerProfile? profile) =>
    profile != null &&
    BuiltinLinux.supported &&
    TermuxMigrationService.eligible(profile);

/// This phone's row for a Termux user: "Move to the in-app server", or
/// "Resume moving…" when a copy did not finish, "Moving…" while it runs, and
/// "Moved to the in-app server" with the reminder that removing Termux is
/// theirs to do. Opens the move. It reads what was saved when it appears;
/// it never looks at Termux by itself.
class TermuxMigrationRow extends ConsumerStatefulWidget {
  const TermuxMigrationRow({super.key, required this.profile, this.owner});

  /// The saved Termux server.
  final ServerProfile profile;

  /// Null is [TermuxMigrationOwner.instance].
  final TermuxMigrationOwner? owner;

  @override
  ConsumerState<TermuxMigrationRow> createState() => _TermuxMigrationRowState();
}

class _TermuxMigrationRowState extends ConsumerState<TermuxMigrationRow> {
  late final TermuxMigrationOwner _owner =
      widget.owner ?? TermuxMigrationOwner.instance;
  bool _unfinished = false;
  bool _moved = false;

  @override
  void initState() {
    super.initState();
    _owner.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_read());
    });
  }

  @override
  void dispose() {
    _owner.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _read() async {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    await _owner.obtain(ref.read(connProvider), l10n.phoneSetupProfileName);
    // Finished is the backend's record; one that cannot be read leaves the
    // plain row, and the page says what happened.
    var moved = false;
    try {
      moved = await _owner.completedJob(widget.profile.id) != null;
    } catch (_) {
      moved = false;
    }
    final saved = moved ? null : await _owner.savedSelection(widget.profile.id);
    if (mounted) {
      setState(() {
        _moved = moved;
        _unfinished = saved != null;
      });
    }
  }

  Future<void> _open() async {
    await openTermuxMigration(context, source: widget.profile);
    if (mounted) unawaited(_read());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final id = widget.profile.id;
    final moved = _moved;
    final running = _owner.copying && _owner.source == id;
    final (title, detail) = running
        ? (l10n.migrationRowRunning, l10n.migrationKeepOpen)
        : moved
        ? (l10n.migrationDoneTitle, l10n.migrationRowDoneBody)
        : _unfinished
        ? (l10n.migrationRowResume, l10n.migrationRowResumeBody)
        : (l10n.migrationTitle, l10n.migrationRowBody);
    return KitRow(
      key: const ValueKey('this-phone-migrate'),
      leading: running
          ? const KitStatusMark(state: KitMarkState.working)
          : KitRow.icon(
              context,
              moved ? AppIconography.check : AppIconography.swap,
            ),
      title: title,
      titleMaxLines: 2,
      supporting: TextSpan(text: detail),
      supportingKey: const ValueKey('this-phone-migrate-detail'),
      supportingMaxLines: 3,
      trailing: const KitChevron(),
      onTap: () => unawaited(_open()),
    );
  }
}

/// The one-time offer under the Termux server's row on Servers: one
/// sentence, "Review what moves", and a close that is remembered for that
/// server (`oc.termuxMigrationOffer.<id>`, swept with the profile). Opening
/// the review starts nothing; once a copy was saved the offer is gone.
class TermuxMigrationOffer extends StatefulWidget {
  const TermuxMigrationOffer({
    super.key,
    required this.profiles,
    required this.store,
    this.dividerAbove = true,
  });

  final List<ServerProfile> profiles;
  final ProfileStore store;

  /// In the servers list: the panel's hairline above the offer.
  final bool dividerAbove;

  @override
  State<TermuxMigrationOffer> createState() => _TermuxMigrationOfferState();
}

class _TermuxMigrationOfferState extends State<TermuxMigrationOffer> {
  bool _dismissed = false;

  ServerProfile? get _source {
    if (!platformCapabilities.supportsTermux) return null;
    for (final profile in widget.profiles) {
      if (offersTermuxMigration(profile)) return profile;
    }
    return null;
  }

  Future<void> _dismiss(ServerProfile source) async {
    setState(() => _dismissed = true);
    try {
      await TermuxMigrationService.dismissOffer(widget.store, source.id);
    } catch (_) {
      // Closed for now; it may come back next time, which is harmless.
    }
  }

  Future<void> _open(ServerProfile source) async {
    await openTermuxMigration(context, source: source);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    if (source == null ||
        _dismissed ||
        // A saved or finished move keeps the backend's journal, which ends
        // the offer (and a discarded copy brings it back unless dismissed).
        !TermuxMigrationService.shouldOffer(widget.store, source.id)) {
      return const SizedBox.shrink();
    }
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.dividerAbove) const KitDivider(inset: KitDividerInset.text),
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            tokens.space4,
            tokens.space2,
            tokens.space2,
            tokens.space2,
          ),
          child: KitNotice.offer(
            key: const ValueKey('termux-migration-offer'),
            message: l10n.migrationOffer,
            icon: AppIconography.swap,
            action: KitAction(
              key: const ValueKey('termux-migration-offer-review'),
              label: l10n.migrationOfferAction,
              onPressed: () => unawaited(_open(source)),
            ),
            onDismiss: () => unawaited(_dismiss(source)),
            dismissKey: const ValueKey('termux-migration-offer-dismiss'),
          ),
        ),
      ],
    );
  }
}
