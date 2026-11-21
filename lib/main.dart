import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'account.dart';
import 'account_panel.dart';
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
  final _account = AccountController();
  ClientState _state = ClientState(discover: !Platform.isIOS);
  ui.Image? _image;
  Timer? _poller;
  Timer? _accountPoller;
  late final Ticker _ticker;
  bool _loadingFrame = false;
  String _lastAddress = '';
  bool _restoringAccount = false;
  bool _requestingRemote = false;
  int _connectionRequest = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker((_) => unawaited(_updateFrame()));
    _accountPoller = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_account.signedIn &&
          !_state.connected &&
          !_state.pending &&
          !_requestingRemote) {
        unawaited(_account.refreshHosts());
      }
    });
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
    if (state.deviceId.isNotEmpty && !_restoringAccount) {
      _restoringAccount = true;
      unawaited(_account.restore(state.deviceId));
    }
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

  Future<void> _connectAccountHost(String id) async {
    final request = ++_connectionRequest;
    setState(() => _requestingRemote = true);
    try {
      final offer = await _account.requestConnection(id);
      if (mounted && request == _connectionRequest) {
        _client?.connectRemote(offer);
      }
    } on AccountException {
      // The account panel already renders the HTTP error from the controller.
    } finally {
      if (mounted && request == _connectionRequest) {
        setState(() => _requestingRemote = false);
      }
    }
  }

  void _cancelConnection() {
    ++_connectionRequest;
    if (_requestingRemote) setState(() => _requestingRemote = false);
    _client?.disconnect();
  }

  Widget _accountSection() => ListenableBuilder(
    listenable: _account,
    builder: (_, _) => AccountPanel(
      server: _account.server,
      enabled: _state.deviceId.isNotEmpty && !_state.pending,
      signedIn: _account.signedIn,
      working:
          _account.phase == AccountPhase.restoring ||
          _account.phase == AccountPhase.signingIn ||
          _account.loadingHosts ||
          _requestingRemote,
      name: _account.userName,
      code: _account.approvalCode ?? '',
      verificationUrl: _account.approvalUri,
      error: _account.error ?? '',
      hosts: [
        for (final host in _account.hosts)
          (id: host.id, name: host.name, online: host.online, busy: host.busy),
      ],
      onSignIn: () => unawaited(_account.signIn(_state.deviceId)),
      onPasswordSignIn: (email, password) async {
        await _account.signInWithPassword(
          _state.deviceId,
          email: email,
          password: password,
        );
        return _account.signedIn ? null : _account.error ?? '登录已取消。';
      },
      onCancel: _account.cancelSignIn,
      onSignOut: () {
        _cancelConnection();
        unawaited(_account.signOut());
      },
      onRefresh: () => unawaited(_account.refreshHosts()),
      onConnect: _connectAccountHost,
      onServerChanged: (address) async {
        await _account.changeServer(address);
        return _account.error;
      },
    ),
  );

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
      _cancelConnection();
    }
  }

  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    _poller?.cancel();
    _accountPoller?.cancel();
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
    _accountPoller?.cancel();
    _account.dispose();
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
      requestingRemote: _requestingRemote,
      account: _accountSection(),
      onConnect: client == null
          ? null
          : (address) {
              _lastAddress = address;
              client.connect(address);
            },
      onCancel: _cancelConnection,
    );
  }
}
