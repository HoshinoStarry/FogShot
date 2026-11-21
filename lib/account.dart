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

/// One authenticated RinCast profile and the PCs visible to that profile.
class AccountProfile {
  const AccountProfile({
    required this.id,
    required this.server,
    required this.user,
    required this.active,
    required this.phase,
    required this.hosts,
    required this.loadingHosts,
    required this.error,
  });

  final String id;
  final Uri server;
  final AccountUser user;
  final bool active;
  final AccountPhase phase;
  final List<AccountHost> hosts;
  final bool loadingHosts;
  final String? error;

  String get userId => user.id;
  String get email => user.email;
  String get name => user.name;
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

  // Keep the original key so a v1 single-session value can be migrated in place.
  static const _key = 'fogshot.rincast.account.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// RinCast accounts and cross-network rendezvous client for FogShot.
///
/// Every restored profile keeps independent tokens, host state and refresh
/// state. The active profile is a management and sign-in preference only.
class AccountController extends ChangeNotifier {
  AccountController({
    Uri? server,
    AccountTokenStore? tokenStore,
    String deviceName = 'FogShot',
    String? model,
    Future<void> Function(Duration duration)? wait,
    DateTime Function()? now,
  }) : _server = _normalizeServer(server ?? Uri.parse(rincastDefaultServer)),
       _serverWasExplicit = server != null,
       _tokenStore = tokenStore ?? SecureAccountTokenStore(),
       _deviceName = _normalizeDeviceName(deviceName),
       _model = model ?? Platform.operatingSystem,
       _wait = wait ?? Future<void>.delayed,
       _now = now ?? DateTime.now,
       _http = HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 10);
  }

  final HttpClient _http;
  final AccountTokenStore _tokenStore;
  final String _model;
  final Future<void> Function(Duration duration) _wait;
  final DateTime Function() _now;
  final bool _serverWasExplicit;

  String _deviceName;
  Uri _server;
  AccountPhase _phase = AccountPhase.signedOut;
  final Map<String, _AccountState> _accounts = {};
  String? _activeAccountId;
  String? _error;
  String _deviceId = '';
  _DeviceChallenge? _challenge;
  int _signInGeneration = 0;
  int _restoreGeneration = 0;
  bool _disposed = false;
  Future<void> _storageWrites = Future<void>.value();

  AccountPhase get phase => _phase;
  String get userName => activeAccount?.name ?? '';
  Uri? get approvalUri => _challenge?.verificationUriComplete;
  String? get approvalCode => _challenge?.userCode;
  String? get error => _error;
  String? get activeAccountId => _activeAccountId;
  bool get signedIn => _accounts.isNotEmpty;
  Uri get server => _server;
  String get serverUrl => _server.toString();

  String get deviceName => _deviceName;

  set deviceName(String value) {
    _deviceName = _normalizeDeviceName(value);
  }

  /// Sets the device label used by the next device-code or password sign-in.
  /// The stable [deviceId] continues to bind sign-ins to the same headset.
  void setDeviceName(String value) => deviceName = value;

  List<AccountProfile> get accounts => [
    for (final entry in _accounts.entries)
      AccountProfile(
        id: entry.key,
        server: entry.value.server,
        user: entry.value.session.user,
        active: entry.key == _activeAccountId,
        phase: AccountPhase.signedIn,
        hosts: List<AccountHost>.unmodifiable(entry.value.hosts),
        loadingHosts: entry.value.loadingHosts,
        error: entry.value.error,
      ),
  ];

  AccountProfile? get activeAccount {
    final id = _activeAccountId;
    if (id == null) return null;
    final state = _accounts[id];
    if (state == null) return null;
    return AccountProfile(
      id: id,
      server: state.server,
      user: state.session.user,
      active: true,
      phase: AccountPhase.signedIn,
      hosts: List<AccountHost>.unmodifiable(state.hosts),
      loadingHosts: state.loadingHosts,
      error: state.error,
    );
  }

  /// Legacy active-profile host list.
  List<AccountHost> get hosts => activeAccount?.hosts ?? const [];
  bool get loadingHosts => _accounts.values.any((state) => state.loadingHosts);

  /// Restores every stored profile and migrates an old single v1 session.
  Future<void> restore(String deviceId) async {
    _deviceId = deviceId.trim();
    _cancelSignIn(clearError: true, notify: false);
    final generation = ++_restoreGeneration;
    if (_deviceId.isEmpty) {
      _clearAllAccounts();
      _error = '设备标识不可用，无法恢复账户。';
      _notify();
      return;
    }

    _phase = AccountPhase.restoring;
    _error = null;
    _notify();
    try {
      final raw = await _tokenStore.read();
      if (!_restoreIsCurrent(generation)) return;
      if (raw == null || raw.isEmpty) {
        _clearAllAccounts();
        _notify();
        return;
      }

      final vault = _StoredAccountVault.decode(raw);
      if (!_restoreIsCurrent(generation)) return;
      _accounts
        ..clear()
        ..addEntries(
          vault.accounts.entries.map(
            (entry) => MapEntry(entry.key, _AccountState(entry.value)),
          ),
        );
      _activeAccountId = vault.activeAccountId;
      if (_activeAccountId == null && _accounts.isNotEmpty) {
        _activeAccountId = _accounts.keys.first;
      }
      final active = _activeState;
      if (!_serverWasExplicit && active != null) {
        _server = active.server;
      }
      _phase = _accounts.isEmpty
          ? AccountPhase.signedOut
          : AccountPhase.signedIn;
      _challenge = null;

      if (vault.needsRewrite) {
        try {
          await _persistVault();
        } catch (_) {
          _error = '账户已恢复到当前会话，但无法更新安全存储。';
        }
      }
      _notify();
      if (_accounts.isNotEmpty) await refreshHosts();
    } on FormatException {
      if (!_restoreIsCurrent(generation)) return;
      await _clearStoredVault();
      _clearAllAccounts();
      _error = '保存的登录状态已损坏，请重新登录。';
      _notify();
    } on ArgumentError {
      if (!_restoreIsCurrent(generation)) return;
      await _clearStoredVault();
      _clearAllAccounts();
      _error = '保存的服务器地址无效，请重新登录。';
      _notify();
    } on TypeError {
      if (!_restoreIsCurrent(generation)) return;
      await _clearStoredVault();
      _clearAllAccounts();
      _error = '保存的登录状态已损坏，请重新登录。';
      _notify();
    } catch (_) {
      if (!_restoreIsCurrent(generation)) return;
      _clearAllAccounts();
      _error = '无法读取安全存储中的登录状态。';
      _notify();
    }
  }

  /// Adds by device code. An existing active profile never hides another one.
  Future<void> signIn(String deviceId) => _runSignIn(deviceId, (
    generation,
    loginServer,
  ) async {
    final response = await _request(
      'POST',
      '/device/code',
      server: loginServer,
      body: {'deviceId': _deviceId, 'deviceName': deviceName, 'model': _model},
    );
    _requireSuccess(response, fallback: '无法获取登录码，请稍后重试。');
    if (!_signInIsCurrent(generation)) return null;

    final challenge = _DeviceChallenge.fromJson(
      response.body,
      receivedAt: _now(),
      server: loginServer,
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
        server: loginServer,
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

  /// Adds by email and password, then discards the password immediately.
  Future<void> signInWithPassword(
    String deviceId, {
    required String email,
    required String password,
  }) => _runSignIn(deviceId, (_, loginServer) async {
    final response = await _request(
      'POST',
      '/auth/login',
      server: loginServer,
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
    Future<Map<String, dynamic>?> Function(int generation, Uri server)
    authorize,
  ) async {
    final id = deviceId.trim();
    if (id.isEmpty) {
      _setError('设备标识不可用，无法登录。');
      return;
    }

    ++_restoreGeneration;
    final generation = ++_signInGeneration;
    final loginServer = _server;
    _deviceId = id;
    _phase = AccountPhase.signingIn;
    _challenge = null;
    _error = null;
    _notify();

    try {
      final tokens = await authorize(generation, loginServer);
      if (tokens == null || !_signInIsCurrent(generation)) return;
      await _acceptTokenResponse(
        tokens,
        server: loginServer,
        isCurrent: () => _signInIsCurrent(generation),
      );
      if (!_signInIsCurrent(generation)) return;
      _challenge = null;
      _phase = AccountPhase.signedIn;
      _notify();
      final accountId = _activeAccountId;
      if (accountId != null) await refreshAccountHosts(accountId);
    } on AccountException catch (error) {
      if (!_signInIsCurrent(generation)) return;
      _challenge = null;
      _phase = _accounts.isEmpty
          ? AccountPhase.signedOut
          : AccountPhase.signedIn;
      _error = error.message;
      _notify();
    } catch (_) {
      if (!_signInIsCurrent(generation)) return;
      _challenge = null;
      _phase = _accounts.isEmpty
          ? AccountPhase.signedOut
          : AccountPhase.signedIn;
      _error = '登录失败，请检查网络后重试。';
      _notify();
    }
  }

  /// Invalidates an in-flight sign-in. Existing profiles remain available.
  void cancelSignIn() => _cancelSignIn(clearError: true);

  /// Refreshes all profiles. Calls for one profile are coalesced.
  Future<void> refreshHosts() async {
    final ids = _accounts.keys.toList(growable: false);
    if (ids.isEmpty) {
      _phase = AccountPhase.signedOut;
      _notify();
      return;
    }
    await Future.wait(ids.map(refreshAccountHosts), eagerError: false);
  }

  Future<void> refreshAccountHosts(String accountId) async {
    final state = _accounts[accountId];
    if (state == null) {
      _setError('账户不存在或已退出。');
      return;
    }
    final running = state.refreshingHosts;
    if (running != null) return running;

    final future = _refreshAccountHosts(accountId, state);
    state.refreshingHosts = future;
    try {
      await future;
    } finally {
      if (identical(state.refreshingHosts, future)) {
        state.refreshingHosts = null;
      }
    }
  }

  Future<void> _refreshAccountHosts(
    String accountId,
    _AccountState state,
  ) async {
    state.loadingHosts = true;
    state.error = null;
    _notify();
    try {
      final response = await _authenticatedRequest(state, 'GET', '/pcs');
      _requireSuccess(response, fallback: '无法获取账户中的主机列表。');
      final value = response.body['pcs'];
      if (value is! List) {
        throw const AccountException('bad_response', '服务器返回的主机列表无效。');
      }
      final nextHosts = value.map(_hostFromJson).toList(growable: false);
      if (!_isAccountCurrent(accountId, state)) return;
      state.hosts = nextHosts;
    } on AccountException catch (error) {
      if (_isAccountCurrent(accountId, state)) state.error = error.message;
    } catch (_) {
      if (_isAccountCurrent(accountId, state)) {
        state.error = '无法获取账户中的主机列表。';
      }
    } finally {
      if (_isAccountCurrent(accountId, state)) {
        state.loadingHosts = false;
        _notify();
      }
    }
  }

  /// Changes only the active management/sign-in preference.
  Future<void> selectAccount(String accountId) async {
    final state = _accounts[accountId];
    if (state == null) {
      _setError('账户不存在或已退出。');
      return;
    }
    _activeAccountId = accountId;
    if (!_serverWasExplicit) _server = state.server;
    _phase = AccountPhase.signedIn;
    _error = null;
    try {
      await _persistVault();
    } catch (_) {
      _error = '已选择账户，但无法更新安全存储。';
    }
    _notify();
  }

  /// Returns upstream `/connect` JSON for one exact profile and PC.
  Future<Map<String, dynamic>> requestConnectionForAccount(
    String accountId,
    String hostId,
  ) async {
    final id = hostId.trim();
    if (id.isEmpty) {
      const error = AccountException('bad_request', '主机标识无效。');
      _setError(error.message);
      throw error;
    }
    final state = _accounts[accountId];
    if (state == null) {
      const error = AccountException('not_signed_in', '该 RinCast 账户已退出。');
      _setError(error.message);
      throw error;
    }
    try {
      final response = await _authenticatedRequest(
        state,
        'POST',
        '/connect',
        body: {'pcId': id},
      );
      _requireSuccess(response, fallback: '无法连接该主机。');
      if (_isAccountCurrent(accountId, state)) state.error = null;
      _notify();
      return response.body;
    } on AccountException catch (error) {
      if (_isAccountCurrent(accountId, state)) {
        state.error = error.message;
        _notify();
      } else {
        _setError(error.message);
      }
      rethrow;
    } catch (_) {
      const error = AccountException('connect_failed', '无法连接该主机，请稍后重试。');
      if (_isAccountCurrent(accountId, state)) {
        state.error = error.message;
        _notify();
      } else {
        _setError(error.message);
      }
      throw error;
    }
  }

  /// Legacy request for callers that still route through the active profile.
  Future<Map<String, dynamic>> requestConnection(String hostId) async {
    final state = _activeState;
    if (state == null) {
      const error = AccountException('not_signed_in', '请先登录 RinCast 账户。');
      _setError(error.message);
      throw error;
    }
    return requestConnectionForAccount(_activeAccountId!, hostId);
  }

  /// Removes only the active profile, retaining any other saved profiles.
  Future<void> signOut() async {
    _cancelSignIn(clearError: true, notify: false);
    final id = _activeAccountId;
    if (id == null) {
      _phase = AccountPhase.signedOut;
      _notify();
      return;
    }
    await removeAccount(id);
  }

  /// Logs out and deletes exactly one stored profile.
  Future<void> removeAccount(String accountId) async {
    final state = _accounts[accountId];
    if (state == null) {
      _setError('账户不存在或已退出。');
      return;
    }
    _error = null;
    final refreshToken = state.session.refreshToken;
    try {
      await _request(
        'POST',
        '/auth/logout',
        server: state.server,
        body: {'refreshToken': refreshToken},
      );
    } catch (_) {
      // Removing local credentials must still work while offline.
    }

    state.credentialRevision++;
    state.loadingHosts = false;
    _accounts.remove(accountId);
    if (_activeAccountId == accountId) {
      _activeAccountId = _accounts.isEmpty ? null : _accounts.keys.first;
    }
    final active = _activeState;
    if (!_serverWasExplicit && active != null) _server = active.server;
    _phase = _accounts.isEmpty ? AccountPhase.signedOut : AccountPhase.signedIn;
    try {
      await _persistVault();
    } catch (_) {
      _error = '账户已从当前会话移除，但无法更新安全存储。';
    }
    _notify();
  }

  /// Changes the target server for the next added account. Existing profiles
  /// and their tokens remain untouched.
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

    _cancelSignIn(clearError: true, notify: false);
    _server = next;
    _phase = _accounts.isEmpty ? AccountPhase.signedOut : AccountPhase.signedIn;
    _error = null;
    _notify();
  }

  Future<({int status, Map<String, dynamic> body})> _authenticatedRequest(
    _AccountState state,
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (!_isAccountCurrent(_accountIdForState(state), state)) {
      throw const AccountException('not_signed_in', '请先登录 RinCast 账户。');
    }
    if (!state.session.expiresAt.isAfter(
      _now().add(const Duration(seconds: 30)),
    )) {
      await _refreshAccountAccessToken(state);
    }
    if (!_isAccountCurrent(_accountIdForState(state), state)) {
      throw const AccountException('not_signed_in', '请先登录 RinCast 账户。');
    }

    var response = await _request(
      method,
      path,
      server: state.server,
      body: body,
      accessToken: state.session.accessToken,
    );
    if (response.status == HttpStatus.unauthorized) {
      await _refreshAccountAccessToken(state);
      if (!_isAccountCurrent(_accountIdForState(state), state)) {
        throw const AccountException('not_signed_in', '请先登录 RinCast 账户。');
      }
      response = await _request(
        method,
        path,
        server: state.server,
        body: body,
        accessToken: state.session.accessToken,
      );
    }
    if (response.status == HttpStatus.unauthorized) {
      await _invalidateAccount(state, '登录已失效，请重新登录。');
      throw const AccountException('invalid_refresh_token', '登录已失效，请重新登录。');
    }
    return response;
  }

  Future<void> _refreshAccountAccessToken(_AccountState state) async {
    final running = state.refreshingToken;
    if (running != null) return running;
    final future = _performAccountRefresh(state);
    state.refreshingToken = future;
    try {
      await future;
    } finally {
      if (identical(state.refreshingToken, future)) {
        state.refreshingToken = null;
      }
    }
  }

  Future<void> _performAccountRefresh(_AccountState state) async {
    final revision = state.credentialRevision;
    final response = await _request(
      'POST',
      '/auth/refresh',
      server: state.server,
      body: {'refreshToken': state.session.refreshToken},
    );
    if (response.status == HttpStatus.unauthorized) {
      await _invalidateAccount(state, '登录已失效，请重新登录。');
      throw const AccountException('invalid_refresh_token', '登录已失效，请重新登录。');
    }
    _requireSuccess(response, fallback: '无法续期登录状态。');
    final stored = _StoredSession.fromTokenResponse(
      response.body,
      server: state.server,
      issuedAt: _now(),
    );
    if (!_isAccountCurrent(_accountIdForState(state), state) ||
        revision != state.credentialRevision) {
      throw const AccountException('not_signed_in', '请先登录 RinCast 账户。');
    }
    state.session = stored;
    state.credentialRevision++;
    try {
      await _persistVault();
    } catch (_) {
      _error = '登录令牌已续期，但无法更新安全存储。';
    }
    _notify();
  }

  Future<void> _invalidateAccount(_AccountState state, String message) async {
    final accountId = _accountIdForState(state);
    if (!_isAccountCurrent(accountId, state)) return;
    state.credentialRevision++;
    state.loadingHosts = false;
    _accounts.remove(accountId);
    if (_activeAccountId == accountId) {
      _activeAccountId = _accounts.isEmpty ? null : _accounts.keys.first;
    }
    final active = _activeState;
    if (!_serverWasExplicit && active != null) _server = active.server;
    _phase = _accounts.isEmpty ? AccountPhase.signedOut : AccountPhase.signedIn;
    _error = message;
    try {
      await _persistVault();
    } catch (_) {
      _error = '$message 无法更新安全存储。';
    }
    _notify();
  }

  Future<void> _acceptTokenResponse(
    Map<String, dynamic> body, {
    required Uri server,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) {
      throw const AccountException('not_signed_in', '登录已取消。');
    }
    final stored = _StoredSession.fromTokenResponse(
      body,
      server: server,
      issuedAt: _now(),
    );
    final accountId = _accountId(server, stored.user.id);
    final existing = _accounts[accountId];
    if (existing != null) {
      existing.credentialRevision++;
      existing.session = stored;
    } else {
      _accounts[accountId] = _AccountState(stored);
    }
    _activeAccountId = accountId;
    _server = server;
    try {
      await _persistVault();
    } catch (_) {
      _error = '账户已登录，但无法更新安全存储。';
    }
  }

  Future<({int status, Map<String, dynamic> body})> _request(
    String method,
    String path, {
    Uri? server,
    Map<String, dynamic>? body,
    String? accessToken,
  }) async {
    final target = server ?? _server;
    final uri = target.replace(path: '/api/v1$path');
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

  void _cancelSignIn({required bool clearError, bool notify = true}) {
    _signInGeneration++;
    _challenge = null;
    if (clearError) _error = null;
    _phase = _accounts.isEmpty ? AccountPhase.signedOut : AccountPhase.signedIn;
    if (notify) _notify();
  }

  bool _signInIsCurrent(int generation) =>
      !_disposed && generation == _signInGeneration;

  bool _restoreIsCurrent(int generation) =>
      !_disposed && generation == _restoreGeneration;

  bool _isAccountCurrent(String accountId, _AccountState state) =>
      !_disposed && identical(_accounts[accountId], state);

  String _accountIdForState(_AccountState state) =>
      _accountId(state.server, state.session.user.id);

  _AccountState? get _activeState {
    final id = _activeAccountId;
    return id == null ? null : _accounts[id];
  }

  void _clearAllAccounts() {
    _accounts.clear();
    _activeAccountId = null;
    _phase = AccountPhase.signedOut;
    _challenge = null;
  }

  void _setError(String value) {
    _error = value;
    _notify();
  }

  Future<void> _persistVault() {
    final sessions = <String, _StoredSession>{
      for (final entry in _accounts.entries) entry.key: entry.value.session,
    };
    final vault = _StoredAccountVault(
      accounts: sessions,
      activeAccountId: _activeAccountId,
    );
    return _queueStorage(
      sessions.isEmpty
          ? _tokenStore.clear
          : () => _tokenStore.write(vault.encode()),
    );
  }

  Future<void> _clearStoredVault() async {
    try {
      await _queueStorage(_tokenStore.clear);
    } catch (_) {
      // The in-memory account set is still cleared below.
    }
  }

  Future<void> _queueStorage(Future<void> Function() operation) {
    final queued = _storageWrites.then(
      (_) => operation(),
      onError: (_, _) => operation(),
    );
    _storageWrites = queued.then<void>((_) {}, onError: (_, _) {});
    return queued;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _signInGeneration++;
    _restoreGeneration++;
    _http.close(force: true);
    super.dispose();
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

class _AccountState {
  _AccountState(this.session);

  _StoredSession session;
  List<AccountHost> hosts = const [];
  bool loadingHosts = false;
  String? error;
  int credentialRevision = 0;
  Future<void>? refreshingToken;
  Future<void>? refreshingHosts;

  Uri get server => Uri.parse(session.server);
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

  factory _StoredSession.fromJson(Map<String, dynamic> json) {
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
    final account = AccountUser.fromJson(user);
    if (account.id.isEmpty || account.email.isEmpty) {
      throw const FormatException();
    }
    return _StoredSession(
      server: server,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      user: account,
    );
  }

  Map<String, dynamic> toJson() => {
    'server': server,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toIso8601String(),
    'user': user.toJson(),
  };

  _StoredSession withServer(Uri value) => _StoredSession(
    server: value.toString(),
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: expiresAt,
    user: user,
  );
}

class _StoredAccountVault {
  const _StoredAccountVault({
    required this.accounts,
    required this.activeAccountId,
    this.needsRewrite = false,
  });

  final Map<String, _StoredSession> accounts;
  final String? activeAccountId;
  final bool needsRewrite;

  factory _StoredAccountVault.decode(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    final version = decoded['version'];
    if (version != 2) {
      final session = _StoredSession.fromJson(decoded);
      final server = _normalizeServer(Uri.parse(session.server));
      final normalized = session.withServer(server);
      final id = _accountId(server, normalized.user.id);
      return _StoredAccountVault(
        accounts: {id: normalized},
        activeAccountId: id,
        needsRewrite: true,
      );
    }

    final rawAccounts = decoded['accounts'];
    if (rawAccounts is! Map<String, dynamic>) {
      throw const FormatException();
    }
    final accounts = <String, _StoredSession>{};
    final originalToCanonical = <String, String>{};
    var needsRewrite = false;
    for (final entry in rawAccounts.entries) {
      final raw = entry.value;
      if (raw is! Map<String, dynamic>) {
        needsRewrite = true;
        continue;
      }
      try {
        final session = _StoredSession.fromJson(raw);
        final server = _normalizeServer(Uri.parse(session.server));
        final normalized = session.withServer(server);
        final id = _accountId(server, normalized.user.id);
        accounts[id] = normalized;
        originalToCanonical[entry.key] = id;
        if (id != entry.key) needsRewrite = true;
      } on FormatException {
        needsRewrite = true;
      } on ArgumentError {
        needsRewrite = true;
      } on TypeError {
        needsRewrite = true;
      }
    }
    if (accounts.isEmpty && rawAccounts.isNotEmpty) {
      throw const FormatException();
    }
    final rawActive = decoded['active'] as String?;
    var active = rawActive == null ? null : originalToCanonical[rawActive];
    active ??= rawActive != null && accounts.containsKey(rawActive)
        ? rawActive
        : null;
    if (active == null && accounts.isNotEmpty) {
      active = accounts.keys.first;
      needsRewrite = true;
    }
    return _StoredAccountVault(
      accounts: accounts,
      activeAccountId: active,
      needsRewrite: needsRewrite,
    );
  }

  String encode() => jsonEncode({
    'version': 2,
    'active': activeAccountId,
    'accounts': {
      for (final entry in accounts.entries) entry.key: entry.value.toJson(),
    },
  });
}

Uri _normalizeServer(Uri value) {
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

String _accountId(Uri server, String userId) {
  final serverPart = base64Url
      .encode(utf8.encode(server.toString()))
      .replaceAll('=', '');
  final userPart = base64Url.encode(utf8.encode(userId)).replaceAll('=', '');
  return '$serverPart.$userPart';
}

String _normalizeDeviceName(String value) {
  final name = value.trim();
  return name.isEmpty ? 'FogShot' : name;
}

String _errorCode(Map<String, dynamic> body) {
  final value = body['error'];
  return value is String ? value : '';
}
