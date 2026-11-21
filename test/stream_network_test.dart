import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fogshot/client.dart';
import 'package:fogshot/stream_network.dart';
import 'package:fogshot/stream_view.dart';
import 'package:material_ui/material_ui.dart';

class _NoopClient implements Client {
  final muteCommands = <bool>[];

  @override
  void mute(bool enabled) => muteCommands.add(enabled);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _connectedState = ClientState(
  phase: Phase.connected,
  display: 'display-a',
  displays: [
    (id: 'display-a', name: 'Wide desktop monitor', width: 2560, height: 1440),
  ],
  network: StreamNetwork(
    route: 'lan4',
    rttMs: 24.3,
    lossPercent: 0.2,
    jitterMs: 2.4,
  ),
);

Widget _streamView({
  Client? client,
  ClientState? state,
  double playbackVolume = 1,
  ValueChanged<double>? onVolumeChanged,
  ValueChanged<double>? onVolumeChangeEnd,
}) => MaterialApp(
  home: StreamView(
    client: client ?? _NoopClient(),
    state: state ?? _connectedState,
    images: const {},
    brightness: 1,
    onSettings: () {},
    playbackVolume: playbackVolume,
    onVolumeChanged: onVolumeChanged,
    onVolumeChangeEnd: onVolumeChangeEnd,
  ),
);

void _setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('floating toolbar hides without resizing the stream', (
    tester,
  ) async {
    _setSurface(tester, const Size(640, 360));
    await tester.pumpWidget(_streamView());

    final video = find.byKey(const ValueKey('stream-video-area'));
    final toolbar = find.byKey(const ValueKey('stream-toolbar'));
    final videoBounds = tester.getRect(video);
    final toolbarBounds = tester.getRect(toolbar);
    expect(toolbarBounds.center.dx, closeTo(videoBounds.center.dx, 0.01));
    expect(toolbarBounds.top, greaterThan(videoBounds.top));
    expect(toolbarBounds.width, lessThan(videoBounds.width - 80));
    final displayTitle = tester.widget<Text>(find.text('Wide desktop monitor'));
    expect(displayTitle.maxLines, 1);
    expect(displayTitle.overflow, TextOverflow.ellipsis);

    await tester.pump(const Duration(milliseconds: 2999));
    expect(toolbar, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(toolbar, findsNothing);
    expect(tester.getRect(video), videoBounds);

    await tester.tapAt(videoBounds.center);
    await tester.pump();
    expect(toolbar, findsNothing);

    final reveal = find.byKey(const ValueKey('stream-toolbar-reveal'));
    expect(tester.getSize(reveal), const Size(180, 30));
    await tester.tap(reveal);
    await tester.pump();
    expect(toolbar, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mouse movement and keyboard input reveal the idle toolbar', (
    tester,
  ) async {
    _setSurface(tester, const Size(800, 450));
    await tester.pumpWidget(_streamView());
    final toolbar = find.byKey(const ValueKey('stream-toolbar'));
    await tester.pump(const Duration(seconds: 3));
    expect(toolbar, findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.moveTo(const Offset(400, 240));
    await tester.pump();
    expect(toolbar, findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(toolbar, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(toolbar, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('open keyboard menu keeps the floating toolbar available', (
    tester,
  ) async {
    _setSurface(tester, const Size(800, 450));
    await tester.pumpWidget(_streamView());
    final toolbar = find.byKey(const ValueKey('stream-toolbar'));

    await tester.tap(find.byTooltip('远程输入'));
    await tester.pumpAndSettle();
    expect(find.text('屏幕键盘'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(toolbar, findsOneWidget);
    expect(find.text('屏幕键盘'), findsOneWidget);

    await tester.tapAt(const Offset(20, 420));
    await tester.pumpAndSettle();
    expect(find.text('屏幕键盘'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(toolbar, findsNothing);
  });

  testWidgets('compact stream toolbar keeps network status reachable', (
    tester,
  ) async {
    _setSurface(tester, const Size(280, 450));
    await tester.pumpWidget(_streamView());
    expect(tester.takeException(), isNull);
    final networkButton = find.byKey(const ValueKey('stream-network-button'));
    expect(
      find.descendant(
        of: networkButton,
        matching: find.byIcon(Icons.network_check),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: networkButton, matching: find.text('24 ms')),
      findsOneWidget,
    );
    expect(find.text('局域网 IPv4'), findsNothing);
    await tester.tap(networkButton);
    await tester.pump();
    expect(find.text('网络状态'), findsOneWidget);
    expect(find.text('局域网 IPv4'), findsOneWidget);
    expect(tester.getSize(find.byType(StreamNetworkPanel)).width, 262);
    expect(tester.takeException(), isNull);
  });

  testWidgets('network badge is neutral when quality metrics are unknown', (
    tester,
  ) async {
    _setSurface(tester, const Size(640, 360));
    await tester.pumpWidget(
      _streamView(
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
      ),
    );
    final networkButton = find.byKey(const ValueKey('stream-network-button'));
    expect(
      find.descendant(
        of: networkButton,
        matching: find.byIcon(Icons.help_outline),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: networkButton, matching: find.text('— ms')),
      findsOneWidget,
    );
  });

  testWidgets(
    'toolbar volume popover adjusts playback and mutes independently',
    (tester) async {
      _setSurface(tester, const Size(800, 450));
      final client = _NoopClient();
      final changes = <double>[];
      final ends = <double>[];
      await tester.pumpWidget(
        _streamView(
          client: client,
          playbackVolume: 0.4,
          onVolumeChanged: changes.add,
          onVolumeChangeEnd: ends.add,
        ),
      );

      await tester.tap(find.byTooltip('音量'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('stream-volume-popover')),
        findsOneWidget,
      );
      expect(find.text('40%'), findsOneWidget);

      await tester.tap(find.byTooltip('静音'));
      await tester.pump();
      expect(client.muteCommands, [true]);
      await tester.tap(find.byTooltip('取消静音'));
      await tester.pump();
      expect(client.muteCommands, [true, false]);

      await tester.drag(
        find.byKey(const ValueKey('stream-volume-slider')),
        const Offset(70, 0),
      );
      await tester.pump();
      expect(changes, isNotEmpty);
      expect(ends, hasLength(1));
      expect(ends.single, changes.last);
      expect(find.text('${(changes.last * 100).round()}%'), findsOneWidget);
      expect(client.muteCommands, [true, false]);

      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const ValueKey('stream-toolbar')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('stream-volume-popover')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('关闭音量调节'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const ValueKey('stream-toolbar')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('compact overflow opens the same volume popover', (tester) async {
    _setSurface(tester, const Size(280, 450));
    await tester.pumpWidget(_streamView(playbackVolume: 0.7));

    await tester.tap(find.byTooltip('更多串流操作'));
    await tester.pumpAndSettle();
    expect(find.text('音量 · 70%'), findsOneWidget);
    expect(find.text('静音'), findsOneWidget);

    await tester.tap(find.text('音量 · 70%'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stream-volume-popover')), findsOneWidget);
    expect(find.text('70%'), findsOneWidget);
    expect(find.byTooltip('静音'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop network panel has a bounded scroll viewport', (
    tester,
  ) async {
    _setSurface(tester, const Size(900, 300));
    await tester.pumpWidget(_streamView());
    await tester.tap(find.byKey(const ValueKey('stream-network-button')));
    await tester.pump();

    final panel = find.byType(StreamNetworkPanel);
    expect(tester.getSize(panel).width, 360);
    final scrollView = find.descendant(
      of: panel,
      matching: find.byType(SingleChildScrollView),
    );
    expect(scrollView, findsOneWidget);
    final scrollable = find.descendant(
      of: scrollView,
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(scrollable);
    expect(state.position.maxScrollExtent, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('network panel shows the current connection on a narrow screen', (
    tester,
  ) async {
    _setSurface(tester, const Size(280, 350));
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamNetworkPanel(
            metrics: StreamNetwork.fromJson({
              'route': 'wan6',
              'endpoint': '[2001:db8::8]:38711',
              'rttMs': 24.3,
              'mbps': 18.8,
              'uploadMbps': 0.07,
              'lossPercent': 0.4,
              'streams': [
                {
                  'name': '左屏',
                  'active': true,
                  'codec': 'H.264',
                  'width': 2560,
                  'height': 1440,
                  'receiveFps': 58.4,
                },
                {
                  'name': '右屏',
                  'active': false,
                  'codec': 'AV1 10-bit',
                  'width': 1920,
                  'height': 1080,
                  'decodeMs': 3.2,
                },
              ],
            }),
            onClose: () => closed = true,
          ),
        ),
      ),
    );
    expect(find.text('公网直连 IPv6'), findsOneWidget);
    expect(find.text('[2001:db8::8]:38711'), findsOneWidget);
    expect(find.text('24.3 ms'), findsOneWidget);
    expect(find.text('18.8 Mbps'), findsOneWidget);
    expect(find.text('0.40%'), findsOneWidget);
    await tester.ensureVisible(find.text('右屏'));
    await tester.pump();
    expect(find.text('左屏 · 当前显示器'), findsOneWidget);
    expect(find.text('1920 × 1080'), findsOneWidget);
    expect(find.text('3.2 ms'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭网络状态'));
    expect(closed, isTrue);
  });
}
