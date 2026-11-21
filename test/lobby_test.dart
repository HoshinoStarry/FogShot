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
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
    expect(find.text('附近主机'), findsNothing);
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

  testWidgets('opens account content from the compact header', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var requestingRemote = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Lobby(
              state: const ClientState(discover: false),
              account: const Text('account-content'),
              requestingRemote: requestingRemote,
              onConnect: (_) {},
              onCancel: () {},
            );
          },
        ),
      ),
    );

    await tester.tap(find.byTooltip('RinCast 账户'));
    await tester.pumpAndSettle();

    expect(find.text('account-content'), findsOneWidget);
    update(() => requestingRemote = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('account-content'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('encodes physical keys using the host wire convention', () {
    expect(windowsVirtualKey(PhysicalKeyboardKey.keyA), 0x41);
    expect(windowsVirtualKey(PhysicalKeyboardKey.arrowRight), 0x27);
    expect(windowsVirtualKey(PhysicalKeyboardKey.controlRight), 0xa3);
    expect(windowsVirtualKey(PhysicalKeyboardKey.audioVolumeUp), isNull);
  });

  testWidgets('shows devices from multiple accounts and uses the row account', (
    tester,
  ) async {
    LobbyAccountDevice? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Lobby(
          state: const ClientState(discover: false),
          onConnect: (_) {},
          onCancel: () {},
          remoteDevices: const [
            (
              accountId: 'a',
              account: '工作账号',
              id: 'same-id',
              name: '办公室',
              online: true,
              busy: false,
            ),
            (
              accountId: 'b',
              account: '个人账号',
              id: 'same-id',
              name: '家用电脑',
              online: true,
              busy: false,
            ),
          ],
          onConnectAccount: (device) => selected = device,
        ),
      ),
    );
    expect(find.text('办公室'), findsOneWidget);
    expect(find.text('工作账号'), findsOneWidget);
    expect(find.text('家用电脑'), findsOneWidget);
    await tester.tap(find.text('家用电脑'));
    expect(selected?.accountId, 'b');
    expect(selected?.id, 'same-id');
  });
}
