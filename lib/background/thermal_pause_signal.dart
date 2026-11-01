import 'package:flutter/foundation.dart';

/// True while the heat guard holds work paused or stopped.
///
/// The guard sets it; the connection controller folds it into the one status
/// notification ("Paused · the phone is hot"). The guard no longer posts a
/// notification of its own: one ongoing status says everything.
final ValueNotifier<bool> thermalPauseActive = ValueNotifier<bool>(false);
