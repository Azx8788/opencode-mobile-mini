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
    expect(
      restored.withEnabled(model('a'), true).isEnabled(model('a')),
      isTrue,
    );
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

  group('one provider in one step', () {
    ModelRef gpt(String id) => ModelRef(providerID: 'openai', modelID: id);

    test('a save keeps the ticked few and hides the rest', () {
      // The case that made the form look broken: 79 models served, 2 ticked.
      final library = const ModelLibrary().withEnabledSet(
        'openai',
        enabled: ['gpt-5.6-luna', 'gpt-6-luna'],
        disabled: ['gpt-4o', 'gpt-4.1', 'o3'],
      );
      expect(library.isEnabled(gpt('gpt-5.6-luna')), isTrue);
      expect(library.isEnabled(gpt('gpt-6-luna')), isTrue);
      expect(library.isEnabled(gpt('gpt-4o')), isFalse);
      expect(library.isEnabled(gpt('gpt-4.1')), isFalse);
      expect(library.isEnabled(gpt('o3')), isFalse);
    });

    test('another provider keeps its own list', () {
      final library = const ModelLibrary()
          .withEnabled(
            ModelRef(providerID: 'anthropic', modelID: 'claude'),
            false,
          )
          .withEnabledSet('openai', enabled: ['gpt-4o'], disabled: const []);
      expect(
        library.isEnabled(ModelRef(providerID: 'anthropic', modelID: 'claude')),
        isFalse,
      );
      expect(library.isEnabled(gpt('gpt-4o')), isTrue);
    });

    test('ticking a model again takes it off the deny list', () {
      final library = const ModelLibrary()
          .withEnabledSet('openai', enabled: const [], disabled: ['gpt-4o'])
          .withEnabledSet('openai', enabled: ['gpt-4o'], disabled: const []);
      expect(library.isEnabled(gpt('gpt-4o')), isTrue);
      expect(library.disabled, isEmpty);
    });

    test('a blank provider or blank id changes nothing', () {
      const library = ModelLibrary();
      expect(
        identical(
          library.withEnabledSet('  ', enabled: ['a'], disabled: const []),
          library,
        ),
        isTrue,
      );
      expect(
        library
            .withEnabledSet(
              'openai',
              enabled: const ['  '],
              disabled: const [''],
            )
            .disabled,
        isEmpty,
      );
    });
  });
}
