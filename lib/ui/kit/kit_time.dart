import 'package:flutter/material.dart';

/// The app's one way to write a moment (F15): the clock in the person's
/// 12/24-hour setting and locale ("11:36 PM" or "23:36"), and a moment as
/// that clock alone today, "Sep 25, 11:36 PM" earlier this year and
/// "Sep 25, 2025, 11:36 PM" before. Every "as of", "at" and "since" a
/// screen shows goes through it, so two places never disagree on the
/// format of the same time.
///
/// Not a widget: words only, read from [MaterialLocalizations] and
/// [MediaQuery.alwaysUse24HourFormatOf]. Where neither is in the tree (a
/// bare test), the English defaults stand in.
abstract final class KitTime {
  /// The clock time of [at] in the viewer's local time.
  static String clock(BuildContext context, DateTime at) =>
      clockWith(_material(context), at, use24h: _use24h(context));

  /// [at] as the shortest words that name it from [now]: the clock today,
  /// the day and clock this year, the date and clock before.
  static String moment(BuildContext context, DateTime at, {DateTime? now}) =>
      momentWith(_material(context), at, use24h: _use24h(context), now: now);

  /// [clock] without a [BuildContext], for words built outside the tree.
  static String clockWith(
    MaterialLocalizations material,
    DateTime at, {
    required bool use24h,
  }) => material.formatTimeOfDay(
    TimeOfDay.fromDateTime(at.toLocal()),
    alwaysUse24HourFormat: use24h,
  );

  /// [moment] without a [BuildContext].
  static String momentWith(
    MaterialLocalizations material,
    DateTime at, {
    required bool use24h,
    DateTime? now,
  }) {
    final local = at.toLocal();
    final today = (now ?? DateTime.now()).toLocal();
    final time = clockWith(material, local, use24h: use24h);
    if (local.year == today.year &&
        local.month == today.month &&
        local.day == today.day) {
      return time;
    }
    final day = local.year == today.year
        ? material.formatShortMonthDay(local)
        : material.formatShortDate(local);
    return '$day, $time';
  }

  static MaterialLocalizations _material(BuildContext context) =>
      Localizations.of<MaterialLocalizations>(context, MaterialLocalizations) ??
      const DefaultMaterialLocalizations();

  static bool _use24h(BuildContext context) =>
      MediaQuery.maybeAlwaysUse24HourFormatOf(context) ?? false;
}
