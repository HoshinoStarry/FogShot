import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fogshot/client.dart';
import 'package:fogshot/input.dart';
import 'package:fogshot/lobby.dart';

void main() {
  testWidgets('validates the direct address before starting a session', (
    tester,
  ) async {
    String? address;
    await tester.pumpWidget(
      MaterialApp(
        home: Lobby(
          state: const ClientState(discover: false),
          onConnect: (value) => address = value,
          onCancel: () {},
        ),
      ),
    );
    await tester.enterText(find.byType(TextFormField), '192.168.1.400');
    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(find.text('请输入有效的 IPv4 或 IPv6 地址'), findsOneWidget);
    expect(address, isNull);

    await tester.enterText(find.byType(TextFormField), ' 192.168.1.42:48711 ');
    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(address, '192.168.1.42:48711');
  });

  testWidgets('shows host approval and can cancel on a narrow screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Lobby(
          state: const ClientState(phase: Phase.approval),
          onConnect: (_) {},
          onCancel: () => cancelled = true,
        ),
      ),
    );
    expect(find.textContaining('允许配对'), findsOneWidget);
    await tester.tap(find.text('取消'));
    expect(cancelled, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('encodes physical keys using the host wire convention', () {
    expect(windowsVirtualKey(PhysicalKeyboardKey.keyA), 0x41);
    expect(windowsVirtualKey(PhysicalKeyboardKey.arrowRight), 0x27);
    expect(windowsVirtualKey(PhysicalKeyboardKey.controlRight), 0xa3);
    expect(windowsVirtualKey(PhysicalKeyboardKey.audioVolumeUp), isNull);
  });
}
