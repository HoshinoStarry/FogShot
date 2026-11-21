import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'input.dart';

class StreamView extends StatefulWidget {
  const StreamView({
    super.key,
    required this.client,
    required this.state,
    required this.image,
  });

  final Client client;
  final ClientState state;
  final ui.Image? image;

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

  void _move(Offset position, Size size) {
    client.point(
      (position.dx / size.width).clamp(0, 1).toDouble(),
      (position.dy / size.height).clamp(0, 1).toDouble(),
    );
  }

  void _mouseEvent(PointerEvent event, Size size) {
    _move(event.localPosition, size);
    for (var i = 0; i < _mouseButtons.length; i++) {
      final mask = _mouseButtons[i];
      final pressed = (event.buttons & mask) != 0;
      if (pressed != ((_mouse & mask) != 0)) client.button(i, pressed);
    }
    _mouse = event.buttons;
  }

  void _fingerDown(PointerDownEvent event, Size size) {
    if (_touches.length >= 2) return;
    if (_touches.isEmpty) {
      _move(event.localPosition, size);
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

  void _fingerMove(PointerMoveEvent event, Size size) {
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
        _move(finger.start, size);
        client.button(0, true);
        _dragging = true;
      }
      if (_dragging) _move(point, size);
    }
    _touches[event.pointer] = (
      start: finger.start,
      last: point,
      since: finger.since,
    );
  }

  void _fingerUp(PointerUpEvent event, Size size) {
    final finger = _touches.remove(event.pointer);
    if (finger == null) return;
    if (_dragging) {
      _move(event.localPosition, size);
      client.button(0, false);
    } else if (!_scrolling) {
      final button =
          event.timeStamp - finger.since >= const Duration(milliseconds: 450)
          ? 1
          : 0;
      _move(event.localPosition, size);
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
    setState(() => _compose = !_compose);
    if (!_compose) _focus.requestFocus();
  }

  void _press(int vk) {
    client.key(vk, true);
    client.key(vk, false);
  }

  Widget _video(ui.Image image) {
    return Center(
      child: AspectRatio(
        aspectRatio: image.width / image.height,
        child: LayoutBuilder(
          builder: (context, layout) {
            final size = layout.biggest;
            return MouseRegion(
              onHover: (event) => _move(event.localPosition, size),
              cursor: Client.mobile
                  ? MouseCursor.defer
                  : SystemMouseCursors.none,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) {
                  if (!_compose) _focus.requestFocus();
                  if (event.kind == ui.PointerDeviceKind.mouse) {
                    _mouseEvent(event, size);
                  } else {
                    _fingerDown(event, size);
                  }
                },
                onPointerMove: (event) {
                  if (event.kind == ui.PointerDeviceKind.mouse) {
                    _mouseEvent(event, size);
                  } else {
                    _fingerMove(event, size);
                  }
                },
                onPointerUp: (event) {
                  if (event.kind == ui.PointerDeviceKind.mouse) {
                    _mouseEvent(event, size);
                  } else {
                    _fingerUp(event, size);
                  }
                },
                onPointerCancel: (_) => _release(),
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    client.scroll(
                      event.scrollDelta.dx / 55,
                      -event.scrollDelta.dy / 55,
                    );
                  }
                },
                child: RawImage(
                  image: image,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.low,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final state = widget.state;
    final palette = Theme.of(context).colorScheme;
    return Material(
      color: palette.surfaceContainer,
      child: SizedBox(
        height: 54,
        child: Row(
          children: [
            IconButton(
              tooltip: '隐藏工具栏',
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: () {
                if (_compose) _toggleCompose();
                setState(() => _controls = false);
              },
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, layout) {
                  final display = state.displays
                      .where((item) => item.id == state.display)
                      .firstOrNull;
                  return PopupMenuButton<String>(
                    tooltip: '切换显示器',
                    initialValue: state.display,
                    enabled: state.displays.length > 1,
                    onSelected: (id) {
                      _release();
                      client.display(id);
                    },
                    itemBuilder: (_) => [
                      for (final item in state.displays)
                        PopupMenuItem(
                          value: item.id,
                          child: Text(
                            '${item.name}  ${item.width} × ${item.height}',
                          ),
                        ),
                    ],
                    child: Row(
                      children: [
                        const Icon(Icons.desktop_windows_outlined, size: 19),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            display?.name ?? '远程桌面',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (state.displays.length > 1)
                          const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  );
                },
              ),
            ),
            IconButton(
              tooltip: '发送文字',
              isSelected: _compose,
              icon: const Icon(Icons.keyboard_outlined),
              onPressed: _toggleCompose,
            ),
            IconButton(
              tooltip: _muted ? '取消静音' : '静音',
              icon: Icon(
                _muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
              ),
              onPressed: () {
                setState(() => _muted = !_muted);
                client.mute(_muted);
              },
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '断开连接',
              color: palette.error,
              icon: const Icon(Icons.link_off),
              onPressed: () {
                _release();
                client.mute(false);
                client.disconnect();
              },
            ),
            const SizedBox(width: 6),
          ],
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
    final image = widget.image;
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
                    if (image != null)
                      _video(image)
                    else
                      const Center(child: Text('等待主机画面…')),
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
                  ],
                ),
              ),
              if (_compose) _composer(context),
            ],
          ),
        ),
      ),
    );
  }
}
