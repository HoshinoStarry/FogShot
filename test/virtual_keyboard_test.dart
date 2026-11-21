import 'package:flutter_test/flutter_test.dart';
import 'package:fogshot/virtual_keyboard.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('fits a narrow phone and reports shifted letters', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final events = <({int vk, bool down})>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: VirtualKeyboard(
              onKey: (vk, down) => events.add((vk: vk, down: down)),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('q'), findsOneWidget);
    expect(find.byTooltip('Enter'), findsOneWidget);

    await tester.tap(find.byTooltip('Shift'));
    await tester.pump();
    await tester.tap(find.text('Q'));
    await tester.pump();

    expect(events, [
      (vk: 0x10, down: true),
      (vk: 0x51, down: true),
      (vk: 0x51, down: false),
      (vk: 0x10, down: false),
    ]);
    expect(find.text('q'), findsOneWidget);

    events.clear();
    await tester.tap(find.byTooltip('符号').first);
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.text('@'));
    await tester.pump();

    expect(events, [
      (vk: 0x10, down: true),
      (vk: 0x32, down: true),
      (vk: 0x32, down: false),
      (vk: 0x10, down: false),
    ]);
  });

  testWidgets('releases sticky modifiers and clears them on focus loss', (
    tester,
  ) async {
    final events = <({int vk, bool down})>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              VirtualKeyboard(
                onKey: (vk, down) => events.add((vk: vk, down: down)),
              ),
              TextButton(
                key: const ValueKey('outside'),
                onPressed: () {},
                child: const Text('其他地方'),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Ctrl'));
    await tester.tap(find.byTooltip('Alt'));
    await tester.tap(find.byTooltip('Win'));
    await tester.pump();
    expect(events, isEmpty);
    await tester.tap(find.text('a'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('outside')));
    await tester.pump();

    expect(events, [
      (vk: 0x11, down: true),
      (vk: 0x12, down: true),
      (vk: 0x5b, down: true),
      (vk: 0x41, down: true),
      (vk: 0x41, down: false),
      (vk: 0x5b, down: false),
      (vk: 0x12, down: false),
      (vk: 0x11, down: false),
    ]);

    await tester.tap(find.text('a'));
    await tester.pump();

    expect(events, [
      (vk: 0x11, down: true),
      (vk: 0x12, down: true),
      (vk: 0x5b, down: true),
      (vk: 0x41, down: true),
      (vk: 0x41, down: false),
      (vk: 0x5b, down: false),
      (vk: 0x12, down: false),
      (vk: 0x11, down: false),
      (vk: 0x41, down: true),
      (vk: 0x41, down: false),
    ]);
  });
}
