import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'lobby.dart';
import 'stream_view.dart';

void main(List<String> args) {
  LicenseRegistry.addLicense(() async* {
    const notices = {
      'RinCast': 'RinCast.txt',
      'OpenH264': 'OpenH264.txt',
      'Opus': 'Opus.txt',
      'Monocypher': 'Monocypher.txt',
      'nlohmann/json': 'nlohmann-json.txt',
      'libyuv': 'libyuv.txt',
      'miniaudio': 'miniaudio.txt',
    };
    for (final notice in notices.entries) {
      yield LicenseEntryWithLineBreaks([
        notice.key,
      ], await rootBundle.loadString('licenses/${notice.value}'));
    }
  });
  runApp(
    RinCastApp(
      address: args.length == 2 && args.first == '--connect' ? args.last : null,
    ),
  );
}

class RinCastApp extends StatelessWidget {
  const RinCastApp({super.key, this.address});
  final String? address;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FogShot',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff0d131e),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff79dfbf),
        brightness: Brightness.dark,
      ),
      inputDecorationTheme: const InputDecorationThemeData(
        border: OutlineInputBorder(),
      ),
    ),
    home: SessionPage(address: address),
  );
}

class SessionPage extends StatefulWidget {
  const SessionPage({super.key, this.address});
  final String? address;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Client? _client;
  ClientState _state = ClientState(discover: !Platform.isIOS);
  ui.Image? _image;
  Timer? _poller;
  late final Ticker _ticker;
  bool _loadingFrame = false;
  String _lastAddress = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker((_) => unawaited(_updateFrame()));
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final client = await Client.open();
      if (!mounted) {
        client.dispose();
        return;
      }
      setState(() => _client = client);
      _poller = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _updateState(),
      );
      if (widget.address != null) {
        _lastAddress = widget.address!;
        client.connect(_lastAddress);
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _state = ClientState(
            phase: Phase.failed,
            status: '$error',
            discover: !Platform.isIOS,
          ),
        );
      }
    }
  }

  void _replaceImage(ui.Image? image) {
    final previous = _image;
    _image = image;
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  void _updateState() {
    final state = _client?.poll();
    if (state == null) return;
    if (state.connected && !_ticker.isActive) _ticker.start();
    if (!state.connected && _ticker.isActive) _ticker.stop();
    if (!state.connected && _state.connected) _client?.mute(false);
    setState(() {
      if (!state.connected || state.generation != _state.generation) {
        _replaceImage(null);
      }
      _state = state;
    });
  }

  Future<void> _updateFrame() async {
    if (_loadingFrame || !_state.connected) return;
    final future = _client?.nextFrame(_state.generation);
    if (future == null) return;
    _loadingFrame = true;
    final generation = _state.generation;
    try {
      final image = await future;
      if (!mounted || !_state.connected || generation != _state.generation) {
        image.dispose();
      } else {
        setState(() => _replaceImage(image));
      }
    } catch (error) {
      debugPrint('RinCast video upload: $error');
    } finally {
      _loadingFrame = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _client?.release();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _client?.disconnect();
    }
  }

  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    _poller?.cancel();
    _ticker.stop();
    _client?.dispose();
    _client = null;
    return ui.AppExitResponse.exit;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _poller?.cancel();
    _client?.dispose();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    if (client != null && _state.connected) {
      return StreamView(client: client, state: _state, image: _image);
    }
    return Lobby(
      state: _state,
      initialAddress: _lastAddress,
      onConnect: client == null
          ? null
          : (address) {
              _lastAddress = address;
              client.connect(address);
            },
      onCancel: () => client?.disconnect(),
    );
  }
}
