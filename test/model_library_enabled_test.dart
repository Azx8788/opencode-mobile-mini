// The picker's local subset: everything shows until something is turned off.
//
// The point of the list is that it is a *deny* list. A provider that serves
// four hundred models would otherwise need four hundred entries saved to say
// "show these five", and a new model the provider adds would be hidden by
// default rather than appearing as the server intends.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart' show ModelRef;
import 'package:opencode_mobile/state/model_library.dart';

void main() {
  ModelRef model(String id) => ModelRef(providerID: 'openrouter', modelID: id);

  test('an empty list shows everything', () {
    const library = ModelLibrary();
    expect(library.isEnabled(model('anything')), isTrue);
  });

  test('turning one off hides only that one', () {
    final library = const ModelLibrary().withEnabled(model('a'), false);
    expect(library.isEnabled(model('a')), isFalse);
    expect(library.isEnabled(model('b')), isTrue);
  });

  test('the subset survives a round trip through storage', () {
    final library = const ModelLibrary().withEnabled(model('a'), false);
    final restored = ModelLibrary.fromJson(
      jsonDecode(jsonEncode(library.toJson())),
    );
    expect(restored.isEnabled(model('a')), isFalse);
    expect(restored.isEnabled(model('b')), isTrue);
    expect(restored.withEnabled(model('a'), true).isEnabled(model('a')), isTrue);
  });

  test('an old saved library without the field still shows everything', () {
    final restored = ModelLibrary.fromJson(<String, Object>{
      'favorites': <Object>[],
      'recent': <Object>[],
    });
    expect(restored.isEnabled(model('a')), isTrue);
  });

  test('a model the server no longer serves is dropped from the subset', () {
    final library = const ModelLibrary().withEnabled(model('gone'), false);
    final retained = library.retainWhere((ref) => ref.modelID != 'gone');
    expect(retained.disabled, isEmpty);
  });
}
