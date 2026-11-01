import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'widget_overlay_api.dart';

/// Why a style did not save; each has its own plain sentence on screen.
enum WidgetStyleProblem { stale, unavailable }

/// The style being chosen for one widget: ground, accent, preview size, and
/// the save. Saving closes the host on the native side; a failure keeps the
/// choice so a second try needs no re-picking.
class WidgetStyleController extends ChangeNotifier {
  WidgetStyleController({
    required this.api,
    required this.backgroundId,
    required this.accentId,
  });

  final WidgetOverlayApi api;
  String backgroundId;
  String accentId;
  String previewSize = 'card';
  bool saving = false;
  WidgetStyleProblem? problem;

  void chooseBackground(String value) {
    if (saving || value == backgroundId) return;
    backgroundId = value;
    problem = null;
    notifyListeners();
  }

  void chooseAccent(String value) {
    if (saving || value == accentId) return;
    accentId = value;
    problem = null;
    notifyListeners();
  }

  void choosePreviewSize(String value) {
    if (value == previewSize) return;
    previewSize = value;
    notifyListeners();
  }

  Future<void> save() async {
    if (saving) return;
    saving = true;
    problem = null;
    notifyListeners();
    try {
      await api.saveStyle(background: backgroundId, accent: accentId);
    } on PlatformException catch (e) {
      problem = switch (e.code) {
        'staleSnapshot' ||
        'staleRequest' ||
        'wrongRoute' => WidgetStyleProblem.stale,
        _ => WidgetStyleProblem.unavailable,
      };
    } on Object {
      problem = WidgetStyleProblem.unavailable;
    }
    saving = false;
    notifyListeners();
  }
}
