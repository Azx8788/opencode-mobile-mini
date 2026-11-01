import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/profiles.dart';
import 'widget_action_runner.dart';
import 'widget_status_runner.dart';
import 'widget_v2_contract.dart';

/// Kept separately from main: no UI bootstrap, server startup or lifecycle
/// observer is installed in the temporary engine owned by the tapped service.
@pragma('vm:entry-point')
Future<void> widgetActionMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('oc/widget_action');
  WidgetActionRunner? runner;
  WidgetStatusRunner? statusRunner;
  var executing = false;
  channel.setMethodCallHandler((call) async {
    if (call.method == 'cancel') {
      runner?.cancel();
      statusRunner?.cancel();
      return null;
    }
    if (call.method == 'checkStatus') {
      final args = call.arguments;
      if (executing ||
          args is! Map ||
          args['action'] is! Map ||
          args['deadlineEpochMs'] is! int) {
        return const {'status': 'stale'};
      }
      executing = true;
      final prefs = await SharedPreferences.getInstance();
      statusRunner = WidgetStatusRunner(
        loadProfile: ProfileStore(prefs: prefs).loadForWidgetAction,
        loadTarget: (action, fingerprint) async {
          await prefs.reload();
          return readWidgetActionTarget(prefs, action, fingerprint);
        },
        isCurrent: (ticket) => widgetStatusIsCurrent(prefs, ticket),
      );
      return statusRunner!.check(
        Map<String, dynamic>.from(args['action'] as Map),
        args['deadlineEpochMs'] as int,
      );
    }
    if (call.method != 'execute') throw MissingPluginException();
    final arguments = call.arguments;
    final action = arguments is Map
        ? WidgetAction.fromPlatform(arguments['action'])
        : null;
    if (executing ||
        action == null ||
        arguments['snapshot'] is! Map ||
        arguments['deadlineEpochMs'] is! int) {
      return const {'status': 'rejected', 'error': 'invalidRequest'};
    }
    executing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final store = ProfileStore(prefs: prefs);
      runner = WidgetActionRunner(
        loadProfile: store.loadForWidgetAction,
        loadTarget: (action, fingerprint) async {
          await prefs.reload();
          return readWidgetActionTarget(prefs, action, fingerprint);
        },
        isCurrent: (action, fingerprint) => widgetActionIsCurrent(
          prefs,
          action,
          fingerprint,
          expectedSnapshot: Map<String, dynamic>.from(
            arguments['snapshot'] as Map,
          ),
        ),
      );
      return await runner!.execute(
        action,
        Map<String, dynamic>.from(arguments['snapshot'] as Map),
        arguments['deadlineEpochMs'] as int,
      );
    } catch (_) {
      return WidgetActionResult(
        action.id,
        action.action,
        'rejected',
        'unavailable',
      ).toJson();
    }
  });
  await channel.invokeMethod<void>('ready');
}
