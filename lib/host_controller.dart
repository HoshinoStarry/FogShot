import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum SharingPhase { idle, starting, sharing, stopping }

typedef SharingApproval = ({String id, String name, String address});
typedef TrustedSharingDevice = ({String id, String name});
typedef _HostConnection = ({
  Stream<String> output,
  IOSink input,
  Future<int> exitCode,
  VoidCallback abort,
});

class HostController extends ChangeNotifier {
  HostController() : _spawn = null;

  @visibleForTesting
  HostController.withProcess(this._spawn);

  final Future<Process> Function()? _spawn;

  static String? get _executable {
    final directory = File(Platform.resolvedExecutable).parent;
    if (Platform.isWindows) {
      return '${directory.path}\\host\\fogshot-streamer.exe';
    }
    if (Platform.isMacOS) {
      return '${directory.parent.path}/Helpers/FogShot Host.app/Contents/MacOS/fogshot-streamer';
    }
    return null;
  }

  static bool get available {
    final executable = _executable;
    return executable != null && File(executable).existsSync();
  }

  static Future<Process> _startBundledHost() async {
    final executable = _executable;
    if (executable == null) {
      throw const ProcessException(
        'fogshot-streamer',
        [],
        'Unsupported platform',
      );
    }
    return Process.start(executable, const []);
  }

  SharingPhase phase = SharingPhase.idle;
  String? error;
  SharingApproval? approval;
  List<String> addresses = const [];
  List<TrustedSharingDevice> trustedDevices = const [];
  String? connectedDevice;
  String hostName = '';
  String accountName = '';
  String accountServer = '';
  String cloudStatus = '';
  bool signedIn = false;
  bool allowRemote = false;
  bool updating = false;
  _HostConnection? _connection;
  Future<void>? _launch, _closing;
  Timer? _startupTimeout, _refreshTimer, _replyTimeout;
  int _request = 0;
  String? _waitingFor;
  bool _disposed = false;

  void start() {
    if (phase != SharingPhase.idle) return;
    _closing = null;
    error = null;
    phase = SharingPhase.starting;
    _launch = _start();
    _changed();
  }

  Future<void> _start() async {
    try {
      final connection = await (Platform.isMacOS && _spawn == null
          ? _startMacHost()
          : _startProcess());
      _connection = connection;
      final output = connection.output
          .forEach((line) {
            if (_connection == connection) _receive(line);
          })
          .then<void>((_) {}, onError: (Object _) {});
      unawaited(
        connection.input.done.then<void>((_) {}, onError: (Object _) {}),
      );
      unawaited(
        connection.exitCode.then((code) async {
          await output;
          _exited(connection, code);
        }),
      );
      if (phase != SharingPhase.starting) return;
      _startupTimeout = Timer(const Duration(seconds: 15), () {
        error = '共享主机启动超时。';
        unawaited(stop());
      });
    } on Exception {
      error = '无法启动串流主机。';
      phase = SharingPhase.idle;
      _changed();
    }
  }

  Future<_HostConnection> _startProcess() async {
    final process = await (_spawn ?? _startBundledHost)();
    unawaited(process.stderr.drain<void>());
    return (
      output: _lines(process.stdout),
      input: process.stdin,
      exitCode: process.exitCode,
      abort: () => process.kill(ProcessSignal.sigkill),
    );
  }

  static Stream<String> _lines(Stream<List<int>> source) => source
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  Future<_HostConnection> _startMacHost() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final nonce = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final accepted = Completer<_HostConnection>();
    var closed = false;
    var handedOff = false;
    final listener = server.listen((socket) async {
      final lines = StreamIterator(_lines(socket));
      var verified = false;
      try {
        if (!await lines.moveNext().timeout(const Duration(seconds: 2))) return;
        final hello = jsonDecode(lines.current);
        if (hello is! Map ||
            hello['type'] != 'hello' ||
            hello['nonce'] != nonce ||
            closed ||
            accepted.isCompleted) {
          return;
        }
        verified = true;
        final exited = Completer<int>();
        Stream<String> receive() async* {
          try {
            while (await lines.moveNext()) {
              yield lines.current;
            }
          } finally {
            await lines.cancel();
            socket.destroy();
            exited.complete(0);
          }
        }

        accepted.complete((
          output: receive(),
          input: socket,
          exitCode: exited.future,
          abort: socket.destroy,
        ));
      } on Exception {
        // Only the launched helper's first line can make a connection usable.
      } finally {
        if (!verified) {
          socket.destroy();
          unawaited(lines.cancel());
        }
      }
    });
    try {
      await const MethodChannel('host.hoshino.fogshot/streamer')
          .invokeMethod<void>('launch', {'port': server.port, 'nonce': nonce})
          .timeout(const Duration(seconds: 10));
      final connection = await accepted.future.timeout(
        const Duration(seconds: 12),
      );
      handedOff = true;
      return connection;
    } finally {
      closed = true;
      await listener.cancel();
      await server.close();
      if (!handedOff && accepted.isCompleted) (await accepted.future).abort();
    }
  }

  void _receive(String line) {
    if (_disposed || phase == SharingPhase.stopping) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    switch (decoded['type']) {
      case 'state':
        if (phase == SharingPhase.starting) {
          _startupTimeout?.cancel();
          phase = SharingPhase.sharing;
          _refreshTimer = Timer.periodic(
            const Duration(seconds: 2),
            (_) => _send({'type': 'getState'}),
          );
        }
        final system = decoded['system'];
        if (system is Map &&
            system['addresses'] is List &&
            system['port'] is int) {
          final port = system['port'];
          addresses = [
            for (final address
                in (system['addresses'] as List).whereType<String>())
              if (address.contains(':'))
                '[$address]:$port'
              else
                '$address:$port',
          ];
        }
        final settings = decoded['settings'];
        if (settings is Map) {
          hostName = settings['pcName'] as String? ?? '';
          trustedDevices = [
            for (final device
                in (settings['trustedDevices'] as List? ?? const [])
                    .whereType<Map>())
              if (device['id'] case final String id)
                (id: id, name: device['name'] as String? ?? '客户端'),
          ];
        }
        _readCloud(decoded['cloud']);
        approval = _readApproval(decoded['pendingApproval']);
        final session = decoded['session'];
        connectedDevice = session is Map ? _deviceName(session) : null;
      case 'approval':
        approval = _readApproval(decoded);
      case 'approvalEnded':
        approval = null;
      case 'session':
        connectedDevice = decoded['connected'] == true
            ? _deviceName(decoded)
            : null;
        approval = null;
      case 'cloud':
        _readCloud(decoded['cloud'] ?? decoded);
      case 'reply':
        if (_waitingFor == null || decoded['requestId'] != _waitingFor) return;
        _replyTimeout?.cancel();
        _waitingFor = null;
        updating = false;
        error = decoded['ok'] == true
            ? null
            : (decoded['error'] as String? ?? '操作失败。');
        _readCloud(decoded['cloud']);
        _send({'type': 'getState'});
      case 'error':
        error = decoded['message'] as String? ?? '共享主机无法运行。';
      default:
        return;
    }
    _changed();
  }

  String _deviceName(Map<dynamic, dynamic> message) =>
      message['deviceName'] as String? ?? '已连接的客户端';

  SharingApproval? _readApproval(Object? value) {
    if (value is! Map || value['deviceId'] is! String) return null;
    return (
      id: value['deviceId'] as String,
      name: _deviceName(value),
      address: value['address'] as String? ?? '',
    );
  }

  void _readCloud(Object? value) {
    if (value is! Map) return;
    signedIn = value['signedIn'] == true;
    allowRemote = value['allowRemote'] == true;
    accountName = value['email'] as String? ?? '';
    accountServer = value['server'] as String? ?? '';
    cloudStatus = value['status'] as String? ?? '';
  }

  void answer(
    SharingApproval prompt, {
    required bool allow,
    bool remember = false,
  }) {
    if (approval != prompt) return;
    _send({
      'type': allow ? 'approve' : 'deny',
      'deviceId': prompt.id,
      'remember': remember,
    });
    approval = null;
    _changed();
  }

  void disconnect() => _send({'type': 'disconnect'});

  void removeTrusted(TrustedSharingDevice device) =>
      _sendRequest({'type': 'removeTrusted', 'deviceId': device.id});

  void updateSettings(Map<String, Object> settings) =>
      _sendRequest({'type': 'setSettings', 'settings': settings});

  void signIn(String email, String password) =>
      _sendRequest({'type': 'signIn', 'email': email, 'password': password});

  void signOut() => _sendRequest({'type': 'signOut'});

  void _sendRequest(Map<String, Object> command) {
    if (phase != SharingPhase.sharing || updating) return;
    final requestId = (++_request).toString();
    _waitingFor = requestId;
    updating = true;
    error = null;
    _send({...command, 'requestId': requestId});
    _replyTimeout = Timer(const Duration(seconds: 15), () {
      _waitingFor = null;
      updating = false;
      error = '操作超时。';
      _changed();
    });
    _changed();
  }

  void _send(Map<String, Object> command) {
    _connection?.input.writeln(jsonEncode(command));
  }

  Future<void> stop() {
    if (phase == SharingPhase.idle) return Future.value();
    return _closing ??= _stop();
  }

  Future<void> _stop() async {
    phase = SharingPhase.stopping;
    _changed();
    await _launch;
    final connection = _connection;
    if (connection == null) return;
    _send({'type': 'stop'});
    unawaited(
      connection.input.close().then<void>((_) {}, onError: (Object _) {}),
    );
    try {
      await connection.exitCode.timeout(const Duration(seconds: 6));
    } on TimeoutException {
      connection.abort();
      await connection.exitCode;
    }
  }

  void _exited(_HostConnection connection, int code) {
    if (_connection != connection) return;
    _connection = null;
    _startupTimeout?.cancel();
    _refreshTimer?.cancel();
    _replyTimeout?.cancel();
    if (phase != SharingPhase.stopping && error == null) {
      error = '串流主机已退出（$code）。';
    }
    phase = SharingPhase.idle;
    addresses = const [];
    trustedDevices = const [];
    approval = null;
    connectedDevice = null;
    updating = false;
    _waitingFor = null;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
