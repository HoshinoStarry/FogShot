import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// RinCast 的默认账户服务地址。
///
/// The upstream deployment is pinned to <https://rincast.com>. A custom server
/// may be supplied through [AccountController.changeServer] and must use HTTPS.
const rincastDefaultServer = 'https://rincast.com';

enum AccountPhase { signedOut, restoring, signingIn, signedIn }

class AccountHost {
  const AccountHost({
    required this.id,
    required this.name,
    required this.gpu,
    required this.os,
    required this.version,
    required this.online,
    required this.busy,
    required this.lastSeenAt,
  });

  final String id;
  final String name;
  final String gpu;
  final String os;
  final String version;
  final bool online;
  final bool busy;
  final DateTime? lastSeenAt;
}

class AccountException implements Exception {
  const AccountException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Small persistence seam used by the controller and tests.
abstract interface class AccountTokenStore {
  Future<String?> read();

  Future<void> write(String value);

  Future<void> clear();
}

class SecureAccountTokenStore implements AccountTokenStore {
  SecureAccountTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Ad hoc macOS distributions use the login keychain without sharing entitlements.
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  static const _key = 'fogshot.rincast.account.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// RinCast account and cross-network rendezvous client for FogShot.
///
/// The caller supplies the stable device ID produced by the native session.
/// [signIn] publishes the approval code before polling starts. Its future
/// completes after approval, expiry, cancellation, or an error.
class AccountController extends ChangeNotifier {
  AccountController({
    Uri? server,
    AccountTokenStore? tokenStore,
    this.deviceName = 'FogShot',
    String? model,
    Future<void> Function(Duration duration)? wait,
    DateTime Function()? now,
  }) : _server = _normalizeServer(server ?? Uri.parse(rincastDefaultServer)),
       _serverWasExplicit = server != null,
       _tokenStore = tokenStore ?? SecureAccountTokenStore(),
       _model = model ?? Platform.operatingSystem,
       _wait = wait ?? Future<void>.delayed,
       _now = now ?? DateTime.now,
       _http = HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 10);
  }

  final HttpClient _http;
  final AccountTokenStore _tokenStore;
  final String deviceName;
  final String _model;
  final Future<void> Function(Duration duration) _wait;
  final DateTime Function() _now;

  Uri _server;
  final bool _serverWasExplicit;
  AccountPhase _phase = AccountPhase.signedOut;
  AccountUser? _user;
  _StoredSession? _session;
  List<AccountHost> _hosts = const [];
  String? _error;
  String _deviceId = '';
  _DeviceChallenge? _challenge;
  int _signInGeneration = 0;
  bool _loadingHosts = false;
  bool _disposed = false;
  Future<void>? _refreshing;
  int _sessionGeneration = 0;

  AccountPhase get phase => _phase;
  String get userName => _user?.name ?? '';
  Uri? get approvalUri => _challenge?.verificationUriComplete;
  String? get approvalCode => _challenge?.userCode;
  String? get error => _error;
  List<AccountHost> get hosts => _hosts;
  bool get loadingHosts => _loadingHosts;
  bool get signedIn => _session != null;
  Uri get server => _server;
  String get serverUrl => _server.toString();

  /// Restores a securely stored session and then refreshes the PC list.
  Future<void> restore(String deviceId) async {
    _deviceId = deviceId.trim();
    _cancelSignIn(clearError: true);
    final generation = ++_sessionGeneration;
    _refreshing = null;
    if (_deviceId.isEmpty) {
      _setSignedOut(error: '设备标识不可用，无法恢复账户。');
      return;
    }

    _phase = AccountPhase.restoring;
    _error = null;
    _notify();
    try {
      final raw = await _tokenStore.read();
      if (raw == null || raw.isEmpty) {
        _setSignedOut();
        return;
      }
      final stored = _StoredSession.decode(raw);
      final storedServer = _normalizeServer(Uri.parse(stored.server));
      if (storedServer.toString() != _server.toString()) {
        if (_serverWasExplicit) {
          _setSignedOut(error: '保存的账户属于其他 RinCast 服务器。');
          return;
        }
        _server = storedServer;
      }
      if (!_restoreIsCurrent(generation)) return;
      _session = stored;
      _user = stored.user;
      _phase = AccountPhase.signedIn;
      _notify();
      await refreshHosts();
    } on FormatException {
      await _clearStoredSession();
      _setSignedOut(error: '保存的登录状态已损坏，请重新登录。');
    } on ArgumentError {
      await _clearStoredSession();
      _setSignedOut(error: '保存的服务器地址无效，请重新登录。');
    } catch (_) {
      if (!_restoreIsCurrent(generation)) return;
      _setSignedOut(error: '无法读取安全存储中的登录状态。');
    }
  }

  /// Requests a device code, publishes it, and polls until sign-in finishes.
  Future<void> signIn(String deviceId) => _runSignIn(deviceId, (
    generation,
  ) async {
    final response = await _request(
      'POST',
      '/device/code',
      body: {'deviceId': _deviceId, 'deviceName': deviceName, 'model': _model},
    );
    _requireSuccess(response, fallback: '无法获取登录码，请稍后重试。');
    if (!_signInIsCurrent(generation)) return null;

    final challenge = _DeviceChallenge.fromJson(
      response.body,
      receivedAt: _now(),
      server: _server,
    );
    _challenge = challenge;
    _notify();

    var interval = challenge.interval;
    while (_signInIsCurrent(generation)) {
      if (!_now().add(interval).isBefore(challenge.expiresAt)) {
        throw const AccountException('expired_token', '登录码已过期，请重新获取。');
      }
      await _wait(interval);
      if (!_signInIsCurrent(generation)) return null;

      final poll = await _request(
        'POST',
        '/device/token',
        body: {'deviceCode': challenge.deviceCode},
      );
      if (poll.status == HttpStatus.ok) return poll.body;

      final code = _errorCode(poll.body);
      if (code == 'authorization_pending') continue;
      if (code == 'slow_down') {
        interval += const Duration(seconds: 5);
        continue;
      }
      throw _responseException(poll, fallback: '登录失败，请稍后重试。');
    }
    return null;
  });

  /// Exchanges the registered email and password once for RinCast session tokens.
  Future<void> signInWithPassword(
    String deviceId, {
    required String email,
    required String password,
  }) => _runSignIn(deviceId, (_) async {
    final response = await _request(
      'POST',
      '/auth/login',
      body: {
        'email': email.trim(),
        'password': password,
        'deviceKind': 'headset',
        'deviceId': _deviceId,
        'deviceName': deviceName,
      },
    );
    _requireSuccess(response, fallback: '无法使用邮箱和密码登录，请稍后重试。');
    return response.body;
  });

  Future<void> _runSignIn(
    String deviceId,
    Future<Map<String, dynamic>?> Function(int generation) authorize,
  ) async {
    if (_session != null) {
      _setError('请先退出当前账户。');
      return;
    }
    final id = deviceId.trim();
    if (id.isEmpty) {
      _setError('设备标识不可用，无法登录。');
      return;
    }

    final generation = ++_signInGeneration;
    _deviceId = id;
    _phase = AccountPhase.signingIn;
    _challenge = null;
    _error = null;
    _notify();

    try {
      final tokens = await authorize(generation);
      if (tokens == null || !_signInIsCurrent(generation)) return;
      await _acceptTokenResponse(
        tokens,
        isCurrent: () => _signInIsCurrent(generation),
      );
      if (!_signInIsCurrent(generation)) return;
      _challenge = null;
      _error = null;
      _phase = AccountPhase.signedIn;
      _notify();
      await refreshHosts();
    } on AccountException catch (error) {
      if (!_signInIsCurrent(generation)) return;
      _challenge = null;
      _phase = AccountPhase.signedOut;
      _error = error.message;
      _notify();
    } catch (_) {
      if (!_signInIsCurrent(generation)) return;
      _challenge = null;
      _phase = AccountPhase.signedOut;
      _error = '登录失败，请检查网络后重试。';
      _notify();
    }
  }

  /// Invalidates an in-flight sign-in. A late server response is discarded.
  void cancelSignIn() => _cancelSignIn(clearError: true);

  Future<void> refreshHosts() async {
    if (_session == null) {
      _hosts = const [];
      _setSignedOut();
      return;
    }
    final generation = _sessionGeneration;
    _loadingHosts = true;
    _error = null;
    _notify();
    try {
      final response = await _authenticatedRequest('GET', '/pcs');
      _requireSuccess(response, fallback: '无法获取账户中的主机列表。');
      final value = response.body['pcs'];
      if (value is! List) {
        throw const AccountException('bad_response', '服务器返回的主机列表无效。');
      }
      _hosts = value.map(_hostFromJson).toList(growable: false);
    } on AccountException catch (error) {
      if (generation != _sessionGeneration) return;
      _error = error.message;
    } catch (_) {
      if (generation != _sessionGeneration) return;
      _error = '无法获取账户中的主机列表。';
    } finally {
      if (generation == _sessionGeneration) {
        _loadingHosts = false;
        _notify();
      }
    }
  }

  /// Returns the upstream `/connect` JSON unchanged for the native bridge.
  Future<Map<String, dynamic>> requestConnection(String hostId) async {
    final id = hostId.trim();
    if (id.isEmpty) {
      const error = AccountException('bad_request', '主机标识无效。');
      _setError(error.message);
      throw error;
    }
    try {
      final response = await _authenticatedRequest(
        'POST',
        '/connect',
        body: {'pcId': id},
      );
      _requireSuccess(response, fallback: '无法连接该主机。');
      _error = null;
      _notify();
      return response.body;
    } on AccountException catch (error) {
      _setError(error.message);
      rethrow;
    } catch (_) {
      const error = AccountException('connect_failed', '无法连接该主机，请稍后重试。');
      _setError(error.message);
      throw error;
    }
  }

  /// Signs out locally even when the server cannot be reached.
  Future<void> signOut() async {
    _cancelSignIn(clearError: true);
    ++_sessionGeneration;
    _refreshing = null;
    final refreshToken = _session?.refreshToken;
    if (refreshToken != null) {
      try {
        await _request(
          'POST',
          '/auth/logout',
          body: {'refreshToken': refreshToken},
        );
      } catch (_) {
        // Local credential removal still has to happen when offline.
      }
    }

    String? storageError;
    try {
      await _tokenStore.clear();
    } catch (_) {
      storageError = '已退出当前会话，但无法清除安全存储。';
    }
    _session = null;
    _user = null;
    _hosts = const [];
    _loadingHosts = false;
    _phase = AccountPhase.signedOut;
    _error = storageError;
    _notify();
  }

  /// Switches the account server and clears the active session.
  Future<void> changeServer(String value) async {
    late final Uri next;
    try {
      next = _normalizeServer(Uri.parse(value.trim()));
    } on FormatException {
      _setError('服务器地址无效。');
      return;
    } on ArgumentError catch (error) {
      _setError('${error.message}');
      return;
    }
    if (next == _server) return;

    _cancelSignIn(clearError: true);
    ++_sessionGeneration;
    _refreshing = null;
    _server = next;
    String? storageError;
    try {
      await _tokenStore.clear();
    } catch (_) {
      storageError = '服务器已切换，但无法清除原服务器的登录信息。';
    }
    _session = null;
    _user = null;
    _hosts = const [];
    _loadingHosts = false;
    _phase = AccountPhase.signedOut;
    _error = storageError;
    _notify();
  }

  Future<({int status, Map<String, dynamic> body})> _authenticatedRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (_session == null) {
      _setSignedOut(error: '请先登录 RinCast 账户。');
      throw const AccountException('not_signed_in', '请先登录 RinCast 账户。');
    }
    final generation = _sessionGeneration;
    if (!_session!.expiresAt.isAfter(_now().add(const Duration(seconds: 30)))) {
      await _refreshAccessToken();
      if (generation != _sessionGeneration || _session == null) {
        throw const AccountException('not_signed_in', '请先登录 RinCast 账户。');
      }
    }

    var response = await _request(
      method,
      path,
      body: body,
      accessToken: _session!.accessToken,
    );
    if (response.status == HttpStatus.unauthorized) {
      await _refreshAccessToken();
      if (generation != _sessionGeneration || _session == null) {
        throw const AccountException('not_signed_in', '请先登录 RinCast 账户。');
      }
      response = await _request(
        method,
        path,
        body: body,
        accessToken: _session!.accessToken,
      );
    }
    if (generation != _sessionGeneration) {
      throw const AccountException('not_signed_in', '请先登录 RinCast 账户。');
    }
    if (response.status == HttpStatus.unauthorized) {
      await _clearStoredSession();
      _session = null;
      _user = null;
      _hosts = const [];
      _phase = AccountPhase.signedOut;
      throw const AccountException('invalid_refresh_token', '登录已失效，请重新登录。');
    }
    return response;
  }

  Future<void> _refreshAccessToken() {
    final running = _refreshing;
    if (running != null) return running;
    final completer = Completer<void>();
    final future = completer.future;
    _refreshing = future;
    unawaited(_performRefresh(completer, future));
    return future;
  }

  Future<void> _performRefresh(
    Completer<void> completer,
    Future<void> registeredFuture,
  ) async {
    final generation = _sessionGeneration;
    try {
      final refreshToken = _session?.refreshToken;
      if (refreshToken == null) {
        throw const AccountException('not_signed_in', '请先登录 RinCast 账户。');
      }
      final response = await _request(
        'POST',
        '/auth/refresh',
        body: {'refreshToken': refreshToken},
      );
      if (response.status == HttpStatus.unauthorized) {
        await _clearStoredSession();
        _session = null;
        _user = null;
        _hosts = const [];
        _phase = AccountPhase.signedOut;
        throw const AccountException('invalid_refresh_token', '登录已失效，请重新登录。');
      }
      _requireSuccess(response, fallback: '无法续期登录状态。');
      await _acceptTokenResponse(
        response.body,
        isCurrent: () => generation == _sessionGeneration,
      );
      if (generation != _sessionGeneration) {
        throw const AccountException('not_signed_in', '请先登录 RinCast 账户。');
      }
      _phase = AccountPhase.signedIn;
      _notify();
      completer.complete();
    } catch (error, stackTrace) {
      if (generation != _sessionGeneration && error is! AccountException) {
        completer.completeError(
          const AccountException('not_signed_in', '请先登录 RinCast 账户。'),
          stackTrace,
        );
        return;
      }
      completer.completeError(error, stackTrace);
    } finally {
      if (identical(_refreshing, registeredFuture)) _refreshing = null;
    }
  }

  Future<void> _acceptTokenResponse(
    Map<String, dynamic> body, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) {
      throw const AccountException('not_signed_in', '登录已取消。');
    }
    final stored = _StoredSession.fromTokenResponse(
      body,
      server: _server,
      issuedAt: _now(),
    );
    await _tokenStore.write(stored.encode());
    if (!isCurrent()) {
      await _clearStoredSession();
      throw const AccountException('not_signed_in', '登录已取消。');
    }
    _session = stored;
    _user = stored.user;
  }

  Future<({int status, Map<String, dynamic> body})> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? accessToken,
  }) async {
    final uri = _server.replace(path: '/api/v1$path');
    try {
      final request = await _http
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, 'FogShot/0.1');
      if (accessToken != null) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );
      }
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 15));
      Map<String, dynamic> data = const {};
      if (text.isNotEmpty) {
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) {
          throw const AccountException('bad_response', '服务器返回的数据无效。');
        }
        data = decoded;
      }
      return (status: response.statusCode, body: data);
    } on AccountException {
      rethrow;
    } on TimeoutException {
      throw const AccountException('timeout', 'RinCast 服务器响应超时。');
    } on SocketException {
      throw const AccountException('network', '无法连接 RinCast 服务器，请检查网络。');
    } on HandshakeException {
      throw const AccountException('tls', '无法建立安全连接，请检查服务器证书。');
    } on HttpException {
      throw const AccountException('network', '无法连接 RinCast 服务器，请检查网络。');
    } on FormatException {
      throw const AccountException('bad_response', '服务器返回的数据无效。');
    }
  }

  AccountHost _hostFromJson(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const AccountException('bad_response', '服务器返回的主机信息无效。');
    }
    try {
      return AccountHost(
        id: value['id'] as String,
        name: value['name'] as String,
        gpu: value['gpu'] as String? ?? '',
        os: value['os'] as String? ?? '',
        version: value['version'] as String? ?? '',
        online: value['online'] as bool? ?? false,
        busy: value['busy'] as bool? ?? false,
        lastSeenAt: DateTime.tryParse(value['lastSeenAt'] as String? ?? ''),
      );
    } on TypeError {
      throw const AccountException('bad_response', '服务器返回的主机信息无效。');
    }
  }

  void _requireSuccess(
    ({int status, Map<String, dynamic> body}) response, {
    required String fallback,
  }) {
    if (response.status >= 200 && response.status < 300) return;
    throw _responseException(response, fallback: fallback);
  }

  AccountException _responseException(
    ({int status, Map<String, dynamic> body}) response, {
    required String fallback,
  }) {
    final code = _errorCode(response.body);
    final message = switch (code) {
      'expired_token' => '登录码已过期，请重新获取。',
      'access_denied' => '登录请求被拒绝，请检查账户可连接的设备数量。',
      'slow_down' => '登录服务器要求稍后再试。',
      'invalid_code' => '登录码无效或已过期。',
      'too_many_headsets' => '此账户连接的设备数量已达上限。',
      'too_many_pcs' => '此账户连接的主机数量已达上限。',
      'invalid_credentials' => '邮箱或密码不正确。',
      'pc_offline' => '主机已离线，请确认 RinCast Streamer 正在运行。',
      'not_found' => '未找到该主机。',
      'invalid_refresh_token' => '登录已失效，请重新登录。',
      'unauthorized' => '登录已失效，请重新登录。',
      'rate_limited' => '请求过于频繁，请稍后重试。',
      'bad_request' => '请求内容无效。',
      _ when response.status == HttpStatus.tooManyRequests => '请求过于频繁，请稍后重试。',
      _ => fallback,
    };
    return AccountException(
      code.isEmpty ? 'http_${response.status}' : code,
      message,
    );
  }

  void _cancelSignIn({required bool clearError}) {
    _signInGeneration++;
    _challenge = null;
    if (clearError) _error = null;
    if (_session == null && _phase == AccountPhase.signingIn) {
      _phase = AccountPhase.signedOut;
    }
    _notify();
  }

  bool _signInIsCurrent(int generation) =>
      !_disposed && generation == _signInGeneration;

  bool _restoreIsCurrent(int generation) =>
      !_disposed && generation == _sessionGeneration;

  void _setSignedOut({String? error}) {
    _phase = AccountPhase.signedOut;
    _user = null;
    _session = null;
    _hosts = const [];
    _loadingHosts = false;
    _error = error;
    _notify();
  }

  void _setError(String value) {
    _error = value;
    _notify();
  }

  Future<void> _clearStoredSession() async {
    try {
      await _tokenStore.clear();
    } catch (_) {
      // The in-memory credential is still dropped to prevent further requests.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _signInGeneration++;
    _http.close(force: true);
    super.dispose();
  }

  static Uri _normalizeServer(Uri value) {
    final host = value.host.toLowerCase();
    final loopback =
        host == 'localhost' ||
        host == InternetAddress.loopbackIPv4.address ||
        host == InternetAddress.loopbackIPv6.address;
    if (value.scheme != 'https' && !(value.scheme == 'http' && loopback)) {
      throw ArgumentError('服务器必须使用 HTTPS；本机测试可使用 HTTP。');
    }
    if (host.isEmpty || value.userInfo.isNotEmpty) {
      throw ArgumentError('服务器地址无效。');
    }
    if (value.hasQuery ||
        value.hasFragment ||
        (value.path.isNotEmpty && value.path != '/')) {
      throw ArgumentError('服务器地址只能包含协议、主机和端口。');
    }
    return Uri(
      scheme: value.scheme,
      host: value.host,
      port: value.hasPort ? value.port : null,
    );
  }
}

class AccountUser {
  const AccountUser({
    required this.id,
    required this.email,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String email;
  final String name;
  final DateTime? createdAt;

  factory AccountUser.fromJson(Map<String, dynamic> json) => AccountUser(
    id: json['id'] as String,
    email: json['email'] as String,
    name: json['name'] as String? ?? '',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'name': name,
    'createdAt': createdAt?.toIso8601String(),
  };
}

class _DeviceChallenge {
  const _DeviceChallenge({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUriComplete,
    required this.interval,
    required this.expiresAt,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUriComplete;
  final Duration interval;
  final DateTime expiresAt;

  factory _DeviceChallenge.fromJson(
    Map<String, dynamic> json, {
    required DateTime receivedAt,
    required Uri server,
  }) {
    final deviceCode = json['deviceCode'] as String;
    final userCode = json['userCode'] as String;
    final verificationUriComplete = Uri.parse(
      json['verificationUriComplete'] as String,
    );
    final seconds = json['interval'] as int;
    final expiresIn = json['expiresIn'] as int;
    if (deviceCode.isEmpty ||
        userCode.isEmpty ||
        seconds <= 0 ||
        expiresIn <= 0) {
      throw const FormatException('invalid device challenge');
    }
    final loopback =
        verificationUriComplete.host.toLowerCase() == 'localhost' ||
        verificationUriComplete.host == InternetAddress.loopbackIPv4.address ||
        verificationUriComplete.host == InternetAddress.loopbackIPv6.address;
    final sameDevOrigin =
        server.scheme == 'http' &&
        server.host.toLowerCase() ==
            verificationUriComplete.host.toLowerCase() &&
        server.port == verificationUriComplete.port;
    if (verificationUriComplete.scheme != 'https' &&
        !(loopback && sameDevOrigin)) {
      throw const FormatException('unsafe verification URI');
    }
    return _DeviceChallenge(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUriComplete: verificationUriComplete,
      interval: Duration(seconds: seconds),
      expiresAt: receivedAt.add(Duration(seconds: expiresIn)),
    );
  }
}

class _StoredSession {
  const _StoredSession({
    required this.server,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.user,
  });

  final String server;
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final AccountUser user;

  factory _StoredSession.fromTokenResponse(
    Map<String, dynamic> json, {
    required Uri server,
    required DateTime issuedAt,
  }) {
    final accessToken = json['accessToken'] as String;
    final refreshToken = json['refreshToken'] as String;
    final expiresIn = json['expiresIn'] as int;
    final user = json['user'];
    if (accessToken.isEmpty ||
        refreshToken.isEmpty ||
        expiresIn <= 0 ||
        user is! Map<String, dynamic>) {
      throw const FormatException('invalid token response');
    }
    return _StoredSession(
      server: server.toString(),
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: issuedAt.add(Duration(seconds: expiresIn)),
      user: AccountUser.fromJson(user),
    );
  }

  factory _StoredSession.decode(String value) {
    final json = jsonDecode(value);
    if (json is! Map<String, dynamic>) throw const FormatException();
    final user = json['user'];
    if (user is! Map<String, dynamic>) throw const FormatException();
    final expiresAt = DateTime.tryParse(json['expiresAt'] as String? ?? '');
    final server = json['server'] as String? ?? '';
    final accessToken = json['accessToken'] as String? ?? '';
    final refreshToken = json['refreshToken'] as String? ?? '';
    if (expiresAt == null ||
        server.isEmpty ||
        accessToken.isEmpty ||
        refreshToken.isEmpty) {
      throw const FormatException();
    }
    return _StoredSession(
      server: server,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      user: AccountUser.fromJson(user),
    );
  }

  String encode() => jsonEncode({
    'server': server,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toIso8601String(),
    'user': user.toJson(),
  });
}

String _errorCode(Map<String, dynamic> body) {
  final value = body['error'];
  return value is String ? value : '';
}
