part of '../library_screen.dart';

// Equality only. Unlike inventory identity this deliberately excludes the
// replaceable transport: each explicit action reacquires it in the controller.
Object _authSourceFor(ConnectionController controller) => (
  controller.profile?.id,
  controller.profile?.baseUrl,
  controller.profile?.username,
  controller.profile?.password,
  controller.profile?.flavor,
  controller.locationRevision,
);
