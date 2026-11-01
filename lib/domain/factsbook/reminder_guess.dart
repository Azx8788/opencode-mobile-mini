import 'factsbook_types.dart';

/// A first guess at a reminder from what the person wrote: only to fill the
/// check sheet's fields (the node reads one exact shape in v1, an ISO
/// date-time and a title, and never natural language). The person confirms
/// every field, and the node's own preview is what is saved.
///
/// A reminder is a one-off unless the words say it repeats ("every Monday",
/// "monthly", "every day"): then [repeat] says how, and the sheet shows it.
class ReminderGuess {
  const ReminderGuess({
    required this.what,
    required this.at,
    required this.ambiguities,
    this.repeat = ReminderRepeat.never,
  });

  /// [ReminderRepeat.never] unless the text says it repeats.
  final ReminderRepeat repeat;

  /// The title: the first sentence.
  final String what;
  final DateTime at;

  /// `date` and/or `time` when the text did not say.
  final List<String> ambiguities;

  static const _weekdays = {
    'monday': DateTime.monday,
    'tuesday': DateTime.tuesday,
    'wednesday': DateTime.wednesday,
    'thursday': DateTime.thursday,
    'friday': DateTime.friday,
    'saturday': DateTime.saturday,
    'sunday': DateTime.sunday,
  };

  factory ReminderGuess.from(String text, DateTime now) {
    final lower = text.toLowerCase();
    var date = DateTime(now.year, now.month, now.day + 1);
    final ambiguities = <String>[];
    var found = false;
    for (final entry in _weekdays.entries) {
      if (lower.contains(entry.key)) {
        var ahead = (entry.value - now.weekday) % 7;
        if (ahead == 0 || lower.contains('next ${entry.key}')) ahead += 7;
        date = DateTime(now.year, now.month, now.day + ahead);
        found = true;
        break;
      }
    }
    if (!found) {
      if (lower.contains('today')) {
        date = DateTime(now.year, now.month, now.day);
        found = true;
      } else if (lower.contains('tomorrow')) {
        found = true;
      }
    }
    if (!found) ambiguities.add('date');
    var hour = 9;
    var minute = 0;
    final at = RegExp(
      r'\bat (\d{1,2})(?::(\d{2}))?\s*(am|pm)?',
    ).firstMatch(lower);
    if (at != null) {
      hour = int.parse(at.group(1)!);
      minute = int.tryParse(at.group(2) ?? '0') ?? 0;
      final half = at.group(3);
      if (half == 'pm' && hour < 12) hour += 12;
      if (half == 'am' && hour == 12) hour = 0;
    } else {
      ambiguities.add('time');
    }
    final what = text.split(RegExp(r'[.\n]')).first.trim();
    return ReminderGuess(
      repeat: _repeatOf(lower),
      what: what.isEmpty ? text.trim() : what,
      at: DateTime(
        date.year,
        date.month,
        date.day,
        hour.clamp(0, 23),
        minute.clamp(0, 59),
      ),
      ambiguities: ambiguities,
    );
  }

  /// What the words say about repeating: a one-off when they say nothing.
  static ReminderRepeat _repeatOf(String lower) {
    if (RegExp(
      r'\b(every year|yearly|annually|every anniversary)\b',
    ).hasMatch(lower)) {
      return ReminderRepeat.yearly;
    }
    if (RegExp(r'\b(every month|monthly)\b').hasMatch(lower)) {
      return ReminderRepeat.monthly;
    }
    if (RegExp(
      r'\b(every week|weekly|every (monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b',
    ).hasMatch(lower)) {
      return ReminderRepeat.weekly;
    }
    if (RegExp(
      r'\b(every day|daily|every (morning|evening|night))\b',
    ).hasMatch(lower)) {
      return ReminderRepeat.daily;
    }
    return ReminderRepeat.never;
  }
}
