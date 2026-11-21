import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'input.dart';
import 'microphone_permission.dart';
import 'stream_network.dart';
import 'virtual_keyboard.dart';

class StreamView extends StatefulWidget {
  const StreamView({
    super.key,
    required this.client,
    required this.state,
    required this.images,
    required this.brightness,
    required this.onSettings,
    this.playbackVolume = 1,
    this.onVolumeChanged,
    this.onVolumeChangeEnd,
  });

  final Client client;
  final ClientState state;
  final Map<int, ui.Image> images;
  final double brightness;
  final VoidCallback onSettings;
  final double playbackVolume;
  final ValueChanged<double>? onVolumeChanged;
  final ValueChanged<double>? onVolumeChangeEnd;

  @override
  State<StreamView> createState() => _StreamViewState();
}

class _StreamViewState extends State<StreamView> {
  static const _idleHideDelay = Duration(seconds: 3);

  final _focus = FocusNode(debugLabel: 'Remote input');
  final _text = TextEditingController();
  final _touches = <int, ({Offset start, Offset last, Duration since})>{};
  final _mouseButtons = const [
    kPrimaryMouseButton,
    kSecondaryMouseButton,
    kMiddleMouseButton,
    kBackMouseButton,
    kForwardMouseButton,
  ];
  int _mouse = 0;
  bool _controls = true;
  bool _compose = false;
  bool _muted = false;
  bool _dragging = false;
  bool _scrolling = false;
  bool _showNetwork = false;
  bool _virtualKeyboard = false;
  bool _requestingMic = false;
  bool _menuOpen = false;
  bool _volumeOpen = false;
  late double _volume;
  Timer? _hideTimer;

  Client get client => widget.client;

  @override
  void initState() {
    super.initState();
    _volume = widget.playbackVolume.clamp(0.0, 1.0).toDouble();
    _scheduleIdleHide();
  }

  @override
  void didUpdateWidget(StreamView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playbackVolume != widget.playbackVolume) {
      _volume = widget.playbackVolume.clamp(0.0, 1.0).toDouble();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _scheduleIdleHide() {
    _hideTimer?.cancel();
    if (!mounted ||
        !_controls ||
        _menuOpen ||
        _compose ||
        _virtualKeyboard ||
        _showNetwork ||
        _volumeOpen ||
        _requestingMic) {
      return;
    }
    _hideTimer = Timer(_idleHideDelay, () {
      if (!mounted ||
          !_controls ||
          _menuOpen ||
          _compose ||
          _virtualKeyboard ||
          _showNetwork ||
          _volumeOpen ||
          _requestingMic) {
        return;
      }
      if (_touches.isNotEmpty || _mouse != 0) {
        _scheduleIdleHide();
        return;
      }
      setState(() => _controls = false);
    });
  }

  void _showControls() {
    _hideTimer?.cancel();
    if (!_controls) setState(() => _controls = true);
    _scheduleIdleHide();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    _release();
    setState(() {
      _controls = false;
      _compose = false;
      _showNetwork = false;
      _virtualKeyboard = false;
      _volumeOpen = false;
    });
  }

  void _openMenu() {
    _hideTimer?.cancel();
    _menuOpen = true;
  }

  void _closeMenu() {
    _menuOpen = false;
    _scheduleIdleHide();
  }

  void _toggleVolume() {
    _hideTimer?.cancel();
    setState(() {
      _volumeOpen = !_volumeOpen;
      if (_volumeOpen) _showNetwork = false;
    });
    if (!_volumeOpen) _scheduleIdleHide();
  }

  void _changeVolume(double value) {
    final next = value.clamp(0.0, 1.0).toDouble();
    setState(() => _volume = next);
    widget.onVolumeChanged?.call(next);
  }

  void _finishVolumeChange(double value) {
    widget.onVolumeChangeEnd?.call(value.clamp(0.0, 1.0).toDouble());
  }

  void _release() {
    client.release();
    _touches.clear();
    _mouse = 0;
    _dragging = false;
    _scrolling = false;
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    final vk = windowsVirtualKey(event.physicalKey);
    if (_compose || vk == null || event.synthesized) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyUpEvent) _showControls();
    client.key(vk, event is! KeyUpEvent);
    return KeyEventResult.handled;
  }

  void _move(Offset position, Size size, int streamId) {
    client.point(
      (position.dx / size.width).clamp(0, 1).toDouble(),
      (position.dy / size.height).clamp(0, 1).toDouble(),
      streamId: streamId,
    );
  }

  void _mouseEvent(PointerEvent event, Size size, int streamId) {
    _move(event.localPosition, size, streamId);
    for (var i = 0; i < _mouseButtons.length; i++) {
      final mask = _mouseButtons[i];
      final pressed = (event.buttons & mask) != 0;
      if (pressed != ((_mouse & mask) != 0)) client.button(i, pressed);
    }
    _mouse = event.buttons;
  }

  void _fingerDown(PointerDownEvent event, Size size, int streamId) {
    if (_touches.length >= 2) return;
    if (_touches.isEmpty) {
      _move(event.localPosition, size, streamId);
    } else {
      if (_dragging) client.button(0, false);
      _dragging = false;
      _scrolling = true;
    }
    _touches[event.pointer] = (
      start: event.localPosition,
      last: event.localPosition,
      since: event.timeStamp,
    );
  }

  void _fingerMove(PointerMoveEvent event, Size size, int streamId) {
    final finger = _touches[event.pointer];
    if (finger == null) return;
    final point = event.localPosition;
    if (_scrolling) {
      if (_touches.length == 2) {
        client.scroll(
          (finger.last.dx - point.dx) / 70,
          (point.dy - finger.last.dy) / 70,
        );
      }
    } else {
      if (!_dragging && (finger.start - point).distance > 8) {
        _move(finger.start, size, streamId);
        client.button(0, true);
        _dragging = true;
      }
      if (_dragging) _move(point, size, streamId);
    }
    _touches[event.pointer] = (
      start: finger.start,
      last: point,
      since: finger.since,
    );
  }

  void _fingerUp(PointerUpEvent event, Size size, int streamId) {
    final finger = _touches.remove(event.pointer);
    if (finger == null) return;
    if (_dragging) {
      _move(event.localPosition, size, streamId);
      client.button(0, false);
    } else if (!_scrolling) {
      final button =
          event.timeStamp - finger.since >= const Duration(milliseconds: 450)
          ? 1
          : 0;
      _move(event.localPosition, size, streamId);
      client.button(button, true);
      client.button(button, false);
    }
    _dragging = false;
    if (_touches.isEmpty) _scrolling = false;
  }

  void _submit(String value) {
    if (value.isEmpty) return;
    client.text(value);
    _text.clear();
  }

  void _toggleCompose() {
    _release();
    setState(() {
      _compose = !_compose;
      _virtualKeyboard = false;
      _volumeOpen = false;
    });
    if (_compose) {
      _hideTimer?.cancel();
    } else {
      _scheduleIdleHide();
    }
    if (!_compose) _focus.requestFocus();
  }

  void _press(int vk) {
    client.key(vk, true);
    client.key(vk, false);
  }

  void _toggleVirtualKeyboard() {
    _release();
    setState(() {
      _virtualKeyboard = !_virtualKeyboard;
      _compose = false;
      _volumeOpen = false;
    });
    if (_virtualKeyboard) {
      _hideTimer?.cancel();
    } else {
      _scheduleIdleHide();
    }
  }

  Future<void> _toggleMicrophone() async {
    if (widget.state.microphone) {
      client.microphone(false);
      return;
    }
    if (_requestingMic) return;
    _requestingMic = true;
    _hideTimer?.cancel();
    final granted = await requestMicrophonePermission();
    _requestingMic = false;
    if (!mounted) return;
    if (granted) {
      client.microphone(true);
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('需要麦克风权限才能回传声音。')));
    }
    _scheduleIdleHide();
  }

  Widget _streams() {
    final streams = widget.state.streams;
    if (streams.isEmpty) return const Center(child: Text('等待主机画面…'));
    Widget tile(DisplayStream stream, {bool labeled = false}) {
      final image = widget.images[stream.streamId];
      return Stack(
        fit: StackFit.expand,
        children: [
          if (image == null)
            const Center(child: Text('等待画面…'))
          else
            _video(image, stream.streamId),
          if (labeled)
            Positioned(
              top: 4,
              left: 6,
              right: 6,
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xb01b2028),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      child: Text(
                        stream.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    if (streams.length == 1) return tile(streams.single);
    return LayoutBuilder(
      builder: (_, size) {
        final columns = size.maxWidth < 540 && streams.length <= 3
            ? 1
            : (streams.length <= 4 ? 2 : 3);
        final rows = (streams.length + columns - 1) ~/ columns;
        return Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            children: [
              for (var row = 0; row < rows; ++row)
                Expanded(
                  child: Row(
                    children: [
                      for (var col = 0; col < columns; ++col)
                        Expanded(
                          child: row * columns + col < streams.length
                              ? Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: tile(
                                    streams[row * columns + col],
                                    labeled: true,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _video(ui.Image image, int streamId) {
    return Center(
      child: AspectRatio(
        aspectRatio: image.width / image.height,
        child: LayoutBuilder(
          builder: (context, layout) {
            final size = layout.biggest;
            final picture = RawImage(
              image: image,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
            );
            return MouseRegion(
              onHover: (event) => _move(event.localPosition, size, streamId),
              cursor: Client.mobile
                  ? MouseCursor.defer
                  : SystemMouseCursors.none,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) {
                  if (event.kind == ui.PointerDeviceKind.mouse) {
                    _showControls();
                  }
                  if (!_compose && !_virtualKeyboard) _focus.requestFocus();
                  if (event.kind == ui.PointerDeviceKind.mouse) {
                    _mouseEvent(event, size, streamId);
                  } else {
                    _fingerDown(event, size, streamId);
                  }
                },
                onPointerMove: (event) {
                  if (event.kind == ui.PointerDeviceKind.mouse) {
                    _mouseEvent(event, size, streamId);
                  } else {
                    _fingerMove(event, size, streamId);
                  }
                },
                onPointerUp: (event) {
                  if (event.kind == ui.PointerDeviceKind.mouse) {
                    _mouseEvent(event, size, streamId);
                  } else {
                    _fingerUp(event, size, streamId);
                  }
                },
                onPointerCancel: (_) => _release(),
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    _showControls();
                    _move(event.localPosition, size, streamId);
                    client.scroll(
                      event.scrollDelta.dx / 55,
                      -event.scrollDelta.dy / 55,
                    );
                  }
                },
                child: widget.brightness == 1
                    ? picture
                    : ColorFiltered(
                        colorFilter: ColorFilter.matrix([
                          widget.brightness,
                          0,
                          0,
                          0,
                          0,
                          0,
                          widget.brightness,
                          0,
                          0,
                          0,
                          0,
                          0,
                          widget.brightness,
                          0,
                          0,
                          0,
                          0,
                          0,
                          1,
                          0,
                        ]),
                        child: picture,
                      ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback onPressed, {
    Color? color,
  }) {
    return IconButton(
      iconSize: 19,
      visualDensity: Client.mobile
          ? VisualDensity.standard
          : VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      tooltip: tooltip,
      color: color,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }

  Widget _volumePopover(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    final percent = '${(_volume * 100).round()}%';
    return Material(
      key: const ValueKey('stream-volume-popover'),
      color: palette.surfaceContainerHigh,
      elevation: 12,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
        child: Row(
          children: [
            _action(
              context,
              _muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
              _muted ? '取消静音' : '静音',
              () {
                setState(() => _muted = !_muted);
                client.mute(_muted);
              },
              color: _muted ? palette.error : palette.primary,
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text('播放音量', style: theme.textTheme.labelMedium),
                      const Spacer(),
                      Text(
                        percent,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: palette.primary,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 30,
                    child: SliderTheme(
                      data: theme.sliderTheme.copyWith(
                        trackHeight: 3,
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                      ),
                      child: Slider(
                        key: const ValueKey('stream-volume-slider'),
                        value: _volume,
                        label: percent,
                        onChangeStart: (_) => _hideTimer?.cancel(),
                        onChanged: _changeVolume,
                        onChangeEnd: _finishVolumeChange,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '关闭音量调节',
              visualDensity: VisualDensity.compact,
              onPressed: _toggleVolume,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final state = widget.state;
    final palette = Theme.of(context).colorScheme;
    final display = state.displays
        .where((item) => item.id == state.display)
        .firstOrNull;
    return Material(
      key: const ValueKey('stream-toolbar'),
      color: const Color(0xf2181c22),
      elevation: 14,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: palette.outlineVariant.withValues(alpha: 0.6),
          ),
          borderRadius: BorderRadius.circular(22),
        ),
        child: SizedBox(
          height: Client.mobile ? 48 : 42,
          child: LayoutBuilder(
            builder: (context, bounds) {
              final wide = bounds.maxWidth >= 520;
              final compact = bounds.maxWidth < 420;
              final titleWidth = wide ? 160.0 : (compact ? 50.0 : 112.0);
              final network = state.network;
              final rttKnown = network.rttMs != null;
              final networkKnown =
                  rttKnown ||
                  network.lossPercent != null ||
                  network.jitterMs != null;
              bool atLeast(double? value, double threshold) =>
                  value != null && value >= threshold;
              final networkPoor =
                  atLeast(network.rttMs, 120) ||
                  atLeast(network.lossPercent, 2) ||
                  atLeast(network.jitterMs, 20);
              final networkFair =
                  !networkPoor &&
                  (atLeast(network.rttMs, 60) ||
                      atLeast(network.lossPercent, 0.5) ||
                      atLeast(network.jitterMs, 10));
              final networkIcon = !networkKnown
                  ? Icons.help_outline
                  : networkPoor
                  ? Icons.signal_wifi_bad
                  : networkFair
                  ? Icons.network_ping
                  : Icons.network_check;
              final networkColor = !networkKnown
                  ? palette.onSurfaceVariant
                  : networkPoor
                  ? palette.error
                  : networkFair
                  ? const Color(0xffe0a83b)
                  : const Color(0xff4fbd88);
              final networkQuality = !networkKnown
                  ? '质量未知'
                  : networkPoor
                  ? '网络拥塞'
                  : networkFair
                  ? '网络一般'
                  : '网络流畅';
              final rttLabel = rttKnown
                  ? '${network.rttMs!.round()} ms'
                  : '— ms';

              void toggleMute() {
                setState(() => _muted = !_muted);
                client.mute(_muted);
              }

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!compact)
                    _action(
                      context,
                      Icons.keyboard_arrow_up,
                      '隐藏工具栏',
                      _hideControls,
                    ),
                  SizedBox(
                    width: titleWidth,
                    child: PopupMenuButton<String>(
                      tooltip: '切换显示器',
                      onOpened: _openMenu,
                      onCanceled: _closeMenu,
                      initialValue: state.allDisplays ? '' : state.display,
                      enabled: state.displays.length > 1,
                      onSelected: (id) {
                        _closeMenu();
                        _release();
                        if (id.isEmpty) {
                          client.showAllDisplays();
                        } else {
                          client.display(id);
                        }
                      },
                      itemBuilder: (_) => [
                        if (state.displays.length > 1)
                          const PopupMenuItem(value: '', child: Text('全部显示器')),
                        for (final item in state.displays)
                          PopupMenuItem(
                            value: item.id,
                            child: Text(
                              '${item.name}  ${item.width} × ${item.height}',
                            ),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 7,
                        ),
                        child: Row(
                          children: [
                            if (!compact) ...[
                              const Icon(
                                Icons.desktop_windows_outlined,
                                size: 17,
                              ),
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(
                                state.allDisplays
                                    ? '全部显示器'
                                    : (display?.name ?? '远程桌面'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                            ),
                            if (state.displays.length > 1)
                              const Icon(Icons.arrow_drop_down, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Tooltip(
                    message:
                        '$networkQuality · ${network.routeLabel}\n'
                        'RTT $rttLabel · 丢包 ${network.lossPercent?.toStringAsFixed(2) ?? '—'}%'
                        ' · 波动 ${network.jitterMs?.toStringAsFixed(1) ?? '—'} ms',
                    child: OutlinedButton(
                      key: const ValueKey('stream-network-button'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 30),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: _showNetwork
                            ? palette.primary
                            : palette.onSurface,
                      ),
                      onPressed: () {
                        setState(() {
                          _showNetwork = !_showNetwork;
                          if (_showNetwork) _volumeOpen = false;
                        });
                        _scheduleIdleHide();
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(networkIcon, size: 17, color: networkColor),
                          const SizedBox(width: 4),
                          Text(
                            rttLabel,
                            maxLines: 1,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  PopupMenuButton<int>(
                    tooltip: '远程输入',
                    onOpened: _openMenu,
                    onCanceled: _closeMenu,
                    iconSize: 19,
                    padding: const EdgeInsets.all(6),
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      minimumSize: const Size(34, 34),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    icon: Icon(
                      Icons.keyboard_outlined,
                      color: _compose || _virtualKeyboard
                          ? palette.primary
                          : null,
                    ),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 0,
                        child: Text(_virtualKeyboard ? '隐藏屏幕键盘' : '屏幕键盘'),
                      ),
                      PopupMenuItem(
                        value: 1,
                        child: Text(_compose ? '隐藏文字输入' : '文字输入'),
                      ),
                    ],
                    onSelected: (choice) {
                      _closeMenu();
                      if (choice == 0) {
                        _toggleVirtualKeyboard();
                      } else {
                        _toggleCompose();
                      }
                    },
                  ),
                  if (!compact)
                    _action(
                      context,
                      _volumeOpen ? Icons.volume_up : Icons.volume_up_outlined,
                      '音量',
                      _toggleVolume,
                      color: _volumeOpen || _muted ? palette.primary : null,
                    ),
                  if (wide) ...[
                    _action(
                      context,
                      state.microphone ? Icons.mic : Icons.mic_none,
                      state.microphone ? '关闭麦克风' : '麦克风回传',
                      _toggleMicrophone,
                      color: state.microphone ? palette.primary : null,
                    ),
                    _action(
                      context,
                      Icons.settings_outlined,
                      '串流设置',
                      widget.onSettings,
                    ),
                  ] else ...[
                    PopupMenuButton<int>(
                      tooltip: '更多串流操作',
                      onOpened: _openMenu,
                      onCanceled: _closeMenu,
                      iconSize: 19,
                      padding: const EdgeInsets.all(6),
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: const Size(34, 34),
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 0,
                          child: Text(state.microphone ? '关闭麦克风' : '麦克风回传'),
                        ),
                        const PopupMenuItem(value: 1, child: Text('串流设置')),
                        if (compact) ...[
                          PopupMenuItem(
                            value: 2,
                            child: Text('音量 · ${(_volume * 100).round()}%'),
                          ),
                          PopupMenuItem(
                            value: 3,
                            child: Text(_muted ? '取消静音' : '静音'),
                          ),
                          const PopupMenuItem(value: 4, child: Text('隐藏工具栏')),
                        ],
                      ],
                      onSelected: (choice) {
                        _closeMenu();
                        switch (choice) {
                          case 0:
                            _toggleMicrophone();
                          case 1:
                            widget.onSettings();
                          case 2:
                            _toggleVolume();
                          case 3:
                            toggleMute();
                          case 4:
                            _hideControls();
                        }
                      },
                    ),
                  ],
                  if (!compact)
                    SizedBox(
                      height: 19,
                      child: VerticalDivider(
                        width: 10,
                        color: palette.outlineVariant,
                      ),
                    ),
                  _action(context, Icons.link_off, '断开连接', () {
                    _release();
                    client.disconnect();
                  }, color: palette.error),
                  const SizedBox(width: 3),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _composer(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                autofocus: true,
                textInputAction: TextInputAction.send,
                onSubmitted: _submit,
                decoration: const InputDecoration(
                  hintText: '输入文字后发送',
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              tooltip: '发送文字',
              onPressed: () => _submit(_text.text),
              icon: const Icon(Icons.send_outlined),
            ),
            IconButton(
              tooltip: '远程退格',
              onPressed: () => _press(0x08),
              icon: const Icon(Icons.backspace_outlined),
            ),
            IconButton(
              tooltip: '远程回车',
              onPressed: () => _press(0x0d),
              icon: const Icon(Icons.keyboard_return),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final networkUsesAvailableWidth = Client.mobile || viewportWidth < 400;
    final networkPanelWidth = (viewportWidth - 18).clamp(0.0, 360.0).toDouble();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _key,
          onFocusChange: (focused) {
            if (!focused) _release();
          },
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MouseRegion(
                      onHover: (_) => _showControls(),
                      child: SizedBox.expand(
                        key: const ValueKey('stream-video-area'),
                        child: _streams(),
                      ),
                    ),
                    if (_controls)
                      Positioned(
                        top: 8,
                        left: 0,
                        right: 0,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 640),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Listener(
                                onPointerDown: (_) => _showControls(),
                                child: MouseRegion(
                                  onEnter: (_) => _hideTimer?.cancel(),
                                  onExit: (_) => _scheduleIdleHide(),
                                  child: _toolbar(context),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_controls && _volumeOpen)
                      Positioned(
                        top: Client.mobile ? 64 : 58,
                        left: 8,
                        right: 8,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 320),
                            child: _volumePopover(context),
                          ),
                        ),
                      ),
                    if (!_controls)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 30,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: MouseRegion(
                            onEnter: (_) => _showControls(),
                            child: GestureDetector(
                              key: const ValueKey('stream-toolbar-reveal'),
                              behavior: HitTestBehavior.opaque,
                              onTap: _showControls,
                              child: SizedBox(
                                width: 180,
                                height: 30,
                                child: Center(
                                  child: Container(
                                    width: 34,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.42,
                                      ),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (widget.state.notice.isNotEmpty)
                      Positioned(
                        left: 14,
                        right: 14,
                        bottom: 12,
                        child: IgnorePointer(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                widget.state.notice,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_showNetwork)
                      Positioned(
                        top: Client.mobile ? 64 : 58,
                        right: 9,
                        left: networkUsesAvailableWidth ? 9 : null,
                        width: networkUsesAvailableWidth
                            ? null
                            : networkPanelWidth,
                        bottom: 9,
                        child: Align(
                          alignment: Alignment.topRight,
                          child: SizedBox(
                            width: networkPanelWidth,
                            child: StreamNetworkPanel(
                              metrics: widget.state.network,
                              onClose: () {
                                setState(() => _showNetwork = false);
                                _scheduleIdleHide();
                              },
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_compose) _composer(context),
              if (_virtualKeyboard) VirtualKeyboard(onKey: client.key),
            ],
          ),
        ),
      ),
    );
  }
}
