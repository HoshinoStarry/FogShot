import 'package:flutter_test/flutter_test.dart';
import 'package:fogshot/client.dart';
import 'package:fogshot/stream_network.dart';
import 'package:fogshot/stream_view.dart';
import 'package:material_ui/material_ui.dart';

class _NoopClient implements Client {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('compact stream toolbar keeps network status reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 450);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: StreamView(
          client: _NoopClient(),
          state: const ClientState(
            phase: Phase.connected,
            display: 'display-a',
            displays: [
              (
                id: 'display-a',
                name: 'Wide desktop monitor',
                width: 2560,
                height: 1440,
              ),
            ],
            network: StreamNetwork(route: 'lan4'),
          ),
          images: const {},
          brightness: 1,
          onSettings: () {},
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(OutlinedButton, '网络'));
    await tester.pump();
    expect(find.text('网络状态'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('network panel shows the current connection on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 350);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamNetworkPanel(
            metrics: StreamNetwork.fromJson({
              'route': 'wan6',
              'rttMs': 24.3,
              'mbps': 18.8,
              'width': 2560,
              'height': 1440,
              'lossPercent': 0.4,
            }),
            onClose: () => closed = true,
          ),
        ),
      ),
    );
    expect(find.text('公网直连 IPv6'), findsOneWidget);
    expect(find.text('24.3 ms'), findsOneWidget);
    expect(find.text('18.8 Mbps'), findsOneWidget);
    expect(find.text('2560 × 1440'), findsOneWidget);
    expect(find.text('0.4%'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭网络状态'));
    expect(closed, isTrue);
  });
}
