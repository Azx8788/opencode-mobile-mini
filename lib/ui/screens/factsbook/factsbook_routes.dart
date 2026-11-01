import 'package:flutter/widgets.dart';

import '../../../domain/factsbook/factsbook_trigger_types.dart';
import '../../kit/kit.dart';
import 'about_you_screen.dart';
import 'areas_screen.dart';
import 'capture_screen.dart';
import 'connect_screen.dart';
import 'event_detail_screen.dart';
import 'memory_care_screen.dart';
import 'not_saved_screen.dart';
import 'phone_node_screen.dart';
import 'rule_editor_screen.dart';
import 'reminders_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'status_screen.dart';
import 'triggers_screen.dart';
import 'thing_screen.dart';

/// The pages of the FactsBook slice, pushed with the kit's one route.
Future<void> openFactsBookAboutYou(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookAboutYouScreen());

Future<void> openFactsBookCapture(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookCaptureScreen());

/// Needs you is one page: changes to approve, offers and notes not saved.
Future<void> openFactsBookNeedsYou(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookMemoryCareScreen());

Future<void> openFactsBookNotSaved(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookNotSavedScreen());

Future<void> openFactsBookThing(BuildContext context, String id) =>
    pushKitPage<void>(context, (_) => FactsBookThingScreen(thingId: id));

Future<void> openFactsBookSearch(BuildContext context, String query) =>
    pushKitPage<void>(context, (_) => FactsBookSearchScreen(query: query));

Future<void> openFactsBookConnect(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookConnectScreen());

Future<void> openFactsBookReminders(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookRemindersScreen());

Future<void> openFactsBookAreas(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookAreasScreen());

Future<void> openFactsBookStatus(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookStatusScreen());

Future<void> openFactsBookSettings(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookSettingsScreen());

Future<void> openFactsBookTriggers(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookTriggersScreen());

/// The rule editor: a new rule, or [rule] to change.
Future<void> openFactsBookRule(BuildContext context, {Rule? rule}) =>
    pushKitPage<void>(context, (_) => FactsBookRuleEditorScreen(rule: rule));

/// "What happened to this message" for one event.
Future<void> openFactsBookEvent(BuildContext context, String eventId) =>
    pushKitPage<void>(context, (_) => FactsBookEventScreen(eventId: eventId));

/// Memory on this phone: FactsBook inside the built-in Linux.
Future<void> openFactsBookPhoneNode(BuildContext context) =>
    pushKitPage<void>(context, (_) => const FactsBookPhoneNodeScreen());
