import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_timezone/flutter_timezone.dart';

/// This phone's time zone as an IANA name ("Asia/Dubai"), or null when
/// Android does not say. Memory's home time zone starts as UTC on the node;
/// the app offers this one instead. Tests replace [phoneTimeZoneLoader].
Future<String?> Function() phoneTimeZoneLoader = _deviceZone;

Future<String?> phoneTimeZone() => phoneTimeZoneLoader();

Future<String?> _deviceZone() async {
  // Under `flutter test` the plugin never answers; no answer means no offer.
  if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return null;
  try {
    final id = (await FlutterTimezone.getLocalTimezone()).identifier.trim();
    if (id.isNotEmpty && id != 'Etc/Unknown') return id;
  } on Object {
    // No answer: the app simply does not offer the phone's zone.
  }
  return null;
}
