import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

/// App strings that are safe to read while `initState` is still running or
/// after an `await`, where an inherited lookup is either forbidden or flagged
/// by the analyzer. It walks to the enclosing [Localizations] widget without
/// registering a dependency, so callers do not rebuild on a locale change;
/// use it only for transient copy such as error messages produced by work
/// that starts in `initState`. Everything built in `build` should keep using
/// `Localizations.localeOf(context)` so it follows the language picker live.
AppLocalizations earlyAppLocalizations(BuildContext context) {
  final locale = context.findAncestorWidgetOfExactType<Localizations>()?.locale;
  return lookupAppLocalizations(locale ?? const Locale('en'));
}
