import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/ui/kit/kit_field.dart';

/// The provider key field shows dots with an eye, and must keep doing so
/// without ever reporting itself as a password field: several Android skins
/// swap in their own "secure keyboard" the moment one does. These tests hold
/// the masking to the span, not to `obscureText`.
void main() {
  Future<BuildContext> contextOf(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  String drawn(RedactedController controller, BuildContext context) =>
      controller
          .buildTextSpan(
            context: context,
            style: const TextStyle(),
            withComposing: false,
          )
          .toPlainText();

  testWidgets('a masked secret draws one dot per character', (tester) async {
    final context = await contextOf(tester);
    final controller = RedactedController()..text = 'sk-123456';

    expect(drawn(controller, context), RedactedController.dot * 9);
    // The real value is still there: it is what gets saved.
    expect(controller.text, 'sk-123456');
  });

  testWidgets('the dots follow characters, not code units', (tester) async {
    final context = await contextOf(tester);
    final controller = RedactedController()..text = 'a🔑b';

    expect(drawn(controller, context), RedactedController.dot * 3);
  });

  testWidgets('the eye shows the value and masks it again', (tester) async {
    final context = await contextOf(tester);
    final controller = RedactedController()..text = 'sk-ant-api03-xyz';

    controller.setMasked(false);
    expect(drawn(controller, context), 'sk-ant-api03-xyz');

    controller.setMasked(true);
    expect(drawn(controller, context), RedactedController.dot * 16);
  });

  testWidgets('an empty secret shows its hint, not a row of dots', (
    tester,
  ) async {
    final context = await contextOf(tester);
    final controller = RedactedController();

    expect(drawn(controller, context), isEmpty);
  });

  testWidgets('masking notifies, so the field lays itself out again', (
    tester,
  ) async {
    final controller = RedactedController()..text = 'k';
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.setMasked(false);
    controller.setMasked(false);
    expect(notifications, 1);
  });

  testWidgets('a secret field is not a password field to the platform', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KitField.secret(
            label: 'API key',
            controller: controller,
            revealKey: const ValueKey('reveal'),
            fieldKey: const ValueKey('secret-field'),
          ),
        ),
      ),
    );

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('secret-field')),
        matching: find.byType(TextField),
      ),
    );
    expect(field.obscureText, isFalse);
    expect(find.byKey(const ValueKey('reveal')), findsOneWidget);
  });
}
