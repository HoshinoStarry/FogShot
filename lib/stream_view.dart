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
  });

  final Client client;
  final ClientState state;
  final Map<int, ui.Image> images;
  final double brightness;
  final VoidCallback onSettings;

  @override
  State<StreamView> createState() => _StreamViewState();
}

class _StreamViewState extends State<StreamView> {
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

  Client get client => widget.client;

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
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
    });
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
    });
  }

  Future<void> _toggleMicrophone() async {
    if (widget.state.microphone) {
      client.microphone(false);
      return;
    }
    if (_requestingMic) return;
    _requestingMic = true;
    final granted = await requestMicrophonePermission();
    _requestingMic = false;
    if (!mounted) return;
    if (granted) {
      client.microphone(true);
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('需要麦克风权限才能回传声音。')));
    }
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

  Widget _toolbar(BuildContext context) {
    final state = widget.state;
    final palette = Theme.of(context).colorScheme;
    final display = state.displays
        .where((item) => item.id == state.display)
        .firstOrNull;
    return Material(
      color: const Color(0xff181c22),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.outlineVariant)),
        ),
        child: SizedBox(
          height: Client.mobile ? 48 : 40,
          child: LayoutBuilder(
            builder: (context, bounds) {
              final wide = bounds.maxWidth >= 540;
              final compact = bounds.maxWidth < 360;
              void hideControls() {
                _release();
                setState(() {
                  _controls = false;
                  _compose = false;
                  _showNetwork = false;
                  _virtualKeyboard = false;
                });
              }

              void toggleMute() {
                setState(() => _muted = !_muted);
                client.mute(_muted);
              }

              return Row(
                children: [
                  if (!compact)
                    _action(
                      context,
                      Icons.keyboard_arrow_up,
                      '隐藏工具栏',
                      hideControls,
                    ),
                  Expanded(
                    child: PopupMenuButton<String>(
                      tooltip: '切换显示器',
                      initialValue: state.allDisplays ? '' : state.display,
                      enabled: state.displays.length > 1,
                      onSelected: (id) {
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
                            const Icon(
                              Icons.desktop_windows_outlined,
                              size: 17,
                            ),
                            const SizedBox(width: 6),
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
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Tooltip(
                      message: '网络状态 · ${state.network.routeLabel}',
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 30),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          foregroundColor: _showNetwork
                              ? palette.primary
                              : palette.onSurface,
                        ),
                        onPressed: () =>
                            setState(() => _showNetwork = !_showNetwork),
                        icon: const Icon(Icons.network_check, size: 17),
                        label: Text(
                          wide && state.network.rttMs != null
                              ? '${state.network.routeLabel} · ${state.network.compactLabel}'
                              : (compact && state.network.rttMs == null
                                    ? '网络'
                                    : state.network.compactLabel),
                        ),
                      ),
                    ),
                  ),
                  PopupMenuButton<int>(
                    tooltip: '远程输入',
                    iconSize: 19,
                    padding: const EdgeInsets.all(6),
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
                      _muted
                          ? Icons.volume_off_outlined
                          : Icons.volume_up_outlined,
                      _muted ? '取消静音' : '静音',
                      toggleMute,
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
                      iconSize: 19,
                      padding: const EdgeInsets.all(6),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 0,
                          child: Text(state.microphone ? '关闭麦克风' : '麦克风回传'),
                        ),
                        const PopupMenuItem(value: 1, child: Text('串流设置')),
                        if (compact) ...[
                          PopupMenuItem(
                            value: 2,
                            child: Text(_muted ? '取消静音' : '静音'),
                          ),
                          const PopupMenuItem(value: 3, child: Text('隐藏工具栏')),
                        ],
                      ],
                      onSelected: (choice) {
                        switch (choice) {
                          case 0:
                            _toggleMicrophone();
                          case 1:
                            widget.onSettings();
                          case 2:
                            toggleMute();
                          case 3:
                            hideControls();
                        }
                      },
                    ),
                  ],
                  SizedBox(
                    height: 19,
                    child: VerticalDivider(
                      width: 10,
                      color: palette.outlineVariant,
                    ),
                  ),
                  _action(context, Icons.link_off, '断开连接', () {
                    _release();
                    client.mute(false);
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
              if (_controls) _toolbar(context),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _streams(),
                    if (!_controls)
                      Positioned(
                        left: 8,
                        top: 8,
                        child: IconButton.filledTonal(
                          tooltip: '显示工具栏',
                          icon: const Icon(Icons.keyboard_arrow_down),
                          onPressed: () => setState(() => _controls = true),
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
                        top: 9,
                        right: 9,
                        left: MediaQuery.sizeOf(context).width < 400 ? 9 : null,
                        width: MediaQuery.sizeOf(context).width < 400
                            ? null
                            : 312,
                        bottom: 9,
                        child: Align(
                          alignment: Alignment.topRight,
                          child: StreamNetworkPanel(
                            metrics: widget.state.network,
                            onClose: () => setState(() => _showNetwork = false),
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
