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
import 'desktop_settings.dart';
import 'desktop_settings_dialog.dart';
import 'device_name.dart';
import 'host_controller.dart';
import 'host_dialog.dart';
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
      'dav1d': 'dav1d.txt',
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
  final _host = HostController();
  final _hasHost = HostController.available;
  late final _lobbyChanges = Listenable.merge([_account, _host]);
  bool _hostDialogOpen = false;
  String? _announcedApproval;
  ClientState _state = ClientState(discover: !Platform.isIOS);
  final Map<int, ui.Image> _images = {};
  Timer? _poller;
  Timer? _accountPoller;
  Timer? _reconnectTimer;
  late final Ticker _ticker;
  bool _loadingFrame = false;
  bool _shuttingDown = false;
  String _lastAddress = '';
  bool _restoringAccount = false;
  bool _requestingRemote = false;
  String? _remoteError;
  int _connectionRequest = 0;
  DesktopSettings _settings = DesktopSettings.defaults();
  String _attemptAddress = '';
  String _attemptPcId = '';
  String _attemptPcAccountId = '';
  int _retries = 0;
  bool _shouldReconnect = false;
  Future<void> _settingsWrites = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _host.addListener(_notifyHostApproval);
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

  void _notifyHostApproval() {
    final prompt = _host.approval;
    if (prompt?.id == _announcedApproval) return;
    _announcedApproval = prompt?.id;
    if (prompt == null || _hostDialogOpen || _shuttingDown) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('${prompt.name} 请求配对'),
        action: SnackBarAction(label: '查看', onPressed: _openHost),
      ),
    );
  }

  Future<void> _openHost() async {
    if (_hostDialogOpen || _shuttingDown) return;
    _hostDialogOpen = true;
    await showHostDialog(context, _host);
    _hostDialogOpen = false;
  }

  Future<void> _start() async {
    try {
      final settings = await DesktopSettings.load();
      final deviceName = await currentDeviceName();
      if (_shuttingDown) return;
      _account.setDeviceName(deviceName);
      final client = await Client.open(deviceName: deviceName);
      if (_shuttingDown) {
        client.dispose();
        return;
      }
      client.settings(settings);
      setState(() {
        _settings = settings;
        _lastAddress = settings.lastAddress;
        _client = client;
      });
      _poller = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _updateState(),
      );
      if (widget.address != null) {
        _connectAddress(widget.address!);
      } else if (settings.autoConnect && settings.lastAddress.isNotEmpty) {
        _connectAddress(settings.lastAddress);
      }
    } catch (error) {
      if (mounted && !_shuttingDown) {
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

  void _clearImages() {
    final previous = _images.values.toList();
    _images.clear();
    if (previous.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final image in previous) {
          image.dispose();
        }
      });
    }
  }

  void _updateState() {
    final state = _client?.poll();
    if (state == null) return;
    if (state.deviceId.isNotEmpty && !_restoringAccount) {
      _restoringAccount = true;
      unawaited(_restoreAccount(state.deviceId));
    }
    if (state.connected && !_ticker.isActive) _ticker.start();
    if (!state.connected && _ticker.isActive) _ticker.stop();
    if (!state.connected && _state.connected) {
      _shouldReconnect = state.phase == Phase.failed && _settings.autoReconnect;
    }
    if (state.connected && !_state.connected) {
      _reconnectTimer?.cancel();
      _retries = 0;
      _shouldReconnect = false;
      if (_attemptAddress.isNotEmpty || _attemptPcId.isNotEmpty) {
        _settings = _settings.copyWith(
          lastAddress: _attemptAddress,
          lastPcId: _attemptPcId,
          lastPcAccountId: _attemptPcAccountId,
        );
        unawaited(_persistSettings());
      }
    }
    if (state.phase == Phase.failed && _shouldReconnect) _scheduleReconnect();
    setState(() {
      if (!state.connected || state.generation != _state.generation) {
        _clearImages();
      }
      _state = state;
    });
  }

  Future<void> _restoreAccount(String deviceId) async {
    await _account.restore(deviceId);
    final accountId = _settings.lastPcAccountId.isEmpty
        ? _account.activeAccountId
        : _settings.lastPcAccountId;
    if (mounted &&
        !_shuttingDown &&
        _settings.autoConnect &&
        _settings.lastPcId.isNotEmpty &&
        _connectionRequest == 0 &&
        !_state.connected &&
        !_state.pending &&
        accountId != null &&
        _account.accounts.any((account) => account.id == accountId)) {
      await _connectAccountHost(accountId, _settings.lastPcId);
    }
  }

  void _connectAddress(String address) {
    ++_connectionRequest;
    _attemptPcId = '';
    _attemptPcAccountId = '';
    _attemptAddress = address;
    _lastAddress = address;
    if (_remoteError != null) setState(() => _remoteError = null);
    _client?.connect(address);
  }

  void _scheduleReconnect() {
    if (_reconnectTimer?.isActive == true || _retries >= 3) return;
    final delay = Duration(seconds: 2 << _retries++);
    _reconnectTimer = Timer(delay, () {
      if (!mounted || !_shouldReconnect || _state.connected || _state.pending) {
        return;
      }
      if (_attemptAddress.isNotEmpty) _connectAddress(_attemptAddress);
      if (_attemptPcId.isNotEmpty &&
          _account.accounts.any(
            (account) => account.id == _attemptPcAccountId,
          )) {
        unawaited(_connectAccountHost(_attemptPcAccountId, _attemptPcId));
      }
    });
  }

  Future<void> _connectAccountHost(String accountId, String id) async {
    final request = ++_connectionRequest;
    _attemptAddress = '';
    _attemptPcId = id;
    _attemptPcAccountId = accountId;
    setState(() {
      _requestingRemote = true;
      _remoteError = null;
    });
    try {
      final offer = await _account.requestConnectionForAccount(accountId, id);
      if (mounted && request == _connectionRequest) {
        _client?.connectRemote(offer);
      }
    } on AccountException catch (error) {
      if (mounted && request == _connectionRequest) {
        _remoteError = error.message;
        if (_shouldReconnect) _scheduleReconnect();
      }
    } finally {
      if (mounted && request == _connectionRequest) {
        setState(() => _requestingRemote = false);
      }
    }
  }

  void _cancelConnection() {
    ++_connectionRequest;
    _clearReconnect();
    if (_requestingRemote) setState(() => _requestingRemote = false);
    _client?.disconnect();
  }

  void _clearReconnect() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _retries = 0;
  }

  Future<void> _persistSettings() {
    final snapshot = _settings;
    return _settingsWrites = _settingsWrites.then((_) async {
      try {
        await snapshot.save();
      } on FileSystemException {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('无法保存串流设置。')));
        }
      }
    });
  }

  Future<void> _editSettings() async {
    final result = await showDesktopSettings(
      context,
      _settings,
      supportedCodecs: _state.supportedCodecs,
    );
    if (!mounted || result == null) return;
    setState(() => _settings = result);
    _client?.settings(result);
    await _persistSettings();
  }

  Widget _accountSection() => ListenableBuilder(
    listenable: _account,
    builder: (_, _) => AccountPanel(
      server: _account.server,
      accounts: _account.accounts,
      activeAccountId: _account.activeAccountId,
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
        return _account.error ?? (_account.signedIn ? null : '登录已取消。');
      },
      onCancel: _account.cancelSignIn,
      onSignOut: () {
        _cancelConnection();
        unawaited(_account.signOut());
      },
      onRefresh: () => unawaited(_account.refreshHosts()),
      onConnect: (id) {
        if (_account.activeAccountId case final accountId?) {
          _clearReconnect();
          unawaited(_connectAccountHost(accountId, id));
        }
      },
      onConnectAccount: (accountId, id) {
        _clearReconnect();
        unawaited(_connectAccountHost(accountId, id));
      },
      onSelectAccount: (accountId) =>
          unawaited(_account.selectAccount(accountId)),
      onRemoveAccount: (accountId) async {
        if (_attemptPcAccountId == accountId &&
            (_state.pending || _requestingRemote)) {
          _cancelConnection();
        }
        await _account.removeAccount(accountId);
        return _account.error;
      },
      onServerChanged: (address) async {
        await _account.changeServer(address);
        return _account.error;
      },
    ),
  );

  Future<void> _updateFrame() async {
    if (_loadingFrame || !_state.connected) return;
    final futures = <int, Future<ui.Image>>{};
    for (final stream in _state.streams) {
      final frame = _client?.nextFrame(
        _state.generation,
        streamId: stream.streamId,
      );
      if (frame != null) futures[stream.streamId] = frame;
    }
    if (futures.isEmpty) return;
    _loadingFrame = true;
    final generation = _state.generation;
    try {
      final decoded = await Future.wait(
        futures.entries.map((entry) async {
          try {
            return (entry.key, await entry.value);
          } catch (error) {
            debugPrint('RinCast video upload: $error');
            return null;
          }
        }),
      );
      final frames = decoded.nonNulls;
      if (_shuttingDown ||
          !_state.connected ||
          generation != _state.generation) {
        for (final (_, image) in frames) {
          image.dispose();
        }
        return;
      }
      setState(() {
        for (final (id, image) in frames) {
          final previous = _images[id];
          _images[id] = image;
          if (previous != null) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => previous.dispose(),
            );
          }
        }
      });
    } finally {
      _loadingFrame = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_shuttingDown) return;
    if (state == AppLifecycleState.detached && !Client.mobile) {
      _shutdown();
      return;
    }
    if (state != AppLifecycleState.resumed) _client?.release();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cancelConnection();
    }
  }

  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    _shutdown();
    await _host.stop();
    return ui.AppExitResponse.exit;
  }

  void _shutdown() {
    if (_shuttingDown) return;
    _shuttingDown = true;
    ++_connectionRequest;
    _clearReconnect();
    _poller?.cancel();
    _accountPoller?.cancel();
    _ticker.stop();
    _client?.dispose();
    _client = null;
    unawaited(_host.stop());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shutdown();
    _ticker.dispose();
    _account.dispose();
    _host.dispose();
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    if (client != null && _state.connected) {
      return StreamView(
        client: client,
        state: _state,
        images: _images,
        brightness: _settings.brightness,
        playbackVolume: _settings.playbackVolume,
        onVolumeChanged: (value) {
          setState(() => _settings = _settings.copyWith(playbackVolume: value));
          client.volume(value);
        },
        onVolumeChangeEnd: (_) => unawaited(_persistSettings()),
        onSettings: _editSettings,
      );
    }
    return ListenableBuilder(
      listenable: _lobbyChanges,
      builder: (context, accountPanel) => Lobby(
        state: _state,
        initialAddress: _lastAddress,
        requestingRemote: _requestingRemote,
        remoteError: _remoteError,
        account: accountPanel,
        remoteDevices: [
          for (final account in _account.accounts)
            for (final host in account.hosts)
              (
                accountId: account.id,
                account: account.name.isEmpty ? account.email : account.name,
                id: host.id,
                name: host.name,
                online: host.online,
                busy: host.busy,
              ),
        ],
        onConnectAccount: client == null
            ? null
            : (device) {
                _clearReconnect();
                unawaited(_connectAccountHost(device.accountId, device.id));
              },
        onSettings: _editSettings,
        onShareHost: _hasHost ? _openHost : null,
        sharingHost: _host.phase == SharingPhase.sharing,
        onConnect: client == null
            ? null
            : (address) {
                _clearReconnect();
                _connectAddress(address);
              },
        onCancel: _cancelConnection,
      ),
      child: _accountSection(),
    );
  }
}
