import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fogshot/account.dart';

class _MemoryTokenStore implements AccountTokenStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class _TestAccountServer {
  _TestAccountServer(this.userId, this.email, this.name);

  final String userId;
  final String email;
  final String name;

  late final HttpServer _server;
  String accessToken = 'access-1';
  String refreshToken = 'refresh-1';
  String nextAccessToken = 'access-2';
  String nextRefreshToken = 'refresh-2';
  bool rejectAccess = false;
  bool rejectRefresh = false;

  final List<Map<String, dynamic>> loginBodies = [];
  final List<String?> listAuthorizations = [];
  final List<String?> connectAuthorizations = [];
  final List<Map<String, dynamic>> connectBodies = [];
  String? logoutRefreshToken;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    final body = await _readBody(request);
    switch ((request.method, request.uri.path)) {
      case ('POST', '/api/v1/auth/login'):
        loginBodies.add(body);
        await _write(response, HttpStatus.ok, _tokens());
      case ('POST', '/api/v1/auth/refresh'):
        if (rejectRefresh || body['refreshToken'] != refreshToken) {
          await _write(response, HttpStatus.unauthorized, {
            'error': 'invalid_refresh_token',
          });
          return;
        }
        accessToken = nextAccessToken;
        refreshToken = nextRefreshToken;
        await _write(response, HttpStatus.ok, _tokens());
      case ('POST', '/api/v1/auth/logout'):
        logoutRefreshToken = body['refreshToken'] as String?;
        await _write(response, HttpStatus.ok, {'ok': true});
      case ('GET', '/api/v1/pcs'):
        final authorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        listAuthorizations.add(authorization);
        if (rejectAccess || authorization != 'Bearer $accessToken') {
          await _write(response, HttpStatus.unauthorized, {
            'error': 'unauthorized',
          });
          return;
        }
        await _write(response, HttpStatus.ok, {
          'pcs': [
            {'id': 'pc-1', 'name': name, 'online': true, 'busy': false},
          ],
        });
      case ('POST', '/api/v1/connect'):
        connectAuthorizations.add(
          request.headers.value(HttpHeaders.authorizationHeader),
        );
        connectBodies.add(body);
        await _write(response, HttpStatus.ok, {
          'pcName': name,
          'source': userId,
        });
      default:
        await _write(response, HttpStatus.notFound, {'error': 'not_found'});
    }
  }

  Map<String, dynamic> _tokens() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresIn': 3600,
    'user': {'id': userId, 'email': email, 'name': name},
  };

  Future<Map<String, dynamic>> _readBody(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.isEmpty) return {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _write(HttpResponse response, int status, Object body) async {
    response.statusCode = status;
    response.write(jsonEncode(body));
    await response.close();
  }
}

void main() {
  test('keeps profiles and duplicate PC ids isolated across servers', () async {
    final first = _TestAccountServer('shared-user', 'a@example.com', 'Desk A');
    final second = _TestAccountServer('shared-user', 'b@example.com', 'Desk B');
    await first.start();
    await second.start();
    final store = _MemoryTokenStore();
    final account = AccountController(server: first.uri, tokenStore: store);
    addTearDown(() async {
      account.dispose();
      await first.close();
      await second.close();
    });

    account.setDeviceName('Studio PC');
    await account.signInWithPassword(
      'test-device',
      email: 'a@example.com',
      password: 'password-a',
    );
    expect(first.loginBodies.single['deviceName'], 'Studio PC');

    await account.changeServer(second.uri.toString());
    await account.signInWithPassword(
      'test-device',
      email: 'b@example.com',
      password: 'password-b',
    );

    expect(account.accounts, hasLength(2));
    final firstProfile = account.accounts.singleWhere(
      (profile) => profile.server.port == first.uri.port,
    );
    final secondProfile = account.accounts.singleWhere(
      (profile) => profile.server.port == second.uri.port,
    );
    expect(firstProfile.userId, secondProfile.userId);
    expect(firstProfile.id, isNot(secondProfile.id));
    expect(firstProfile.hosts.single.id, 'pc-1');
    expect(secondProfile.hosts.single.id, 'pc-1');
    expect(account.activeAccountId, secondProfile.id);

    final offer = await account.requestConnectionForAccount(
      firstProfile.id,
      'pc-1',
    );
    expect(offer['pcName'], 'Desk A');
    expect(first.connectAuthorizations.single, 'Bearer access-1');
    expect(first.connectBodies.single, {'pcId': 'pc-1'});
    expect(second.connectBodies, isEmpty);
    expect(account.activeAccountId, secondProfile.id);

    await account.refreshHosts();
    expect(first.listAuthorizations, isNotEmpty);
    expect(second.listAuthorizations, isNotEmpty);

    final persisted = jsonDecode(store.value!) as Map<String, dynamic>;
    expect(persisted['version'], 2);
    expect(
      (persisted['accounts'] as Map).keys,
      containsAll([firstProfile.id, secondProfile.id]),
    );
    expect(persisted['active'], secondProfile.id);
    expect(store.value, isNot(contains('password-a')));
    expect(store.value, isNot(contains('password-b')));

    await account.selectAccount(firstProfile.id);
    final restored = AccountController(tokenStore: store);
    addTearDown(restored.dispose);
    await restored.restore('test-device');
    expect(restored.accounts, hasLength(2));
    expect(restored.activeAccountId, firstProfile.id);
    expect(
      restored.accounts
          .expand((profile) => profile.hosts)
          .where((host) => host.id == 'pc-1'),
      hasLength(2),
    );
  });

  test('migrates the old v1 single session in place', () async {
    final server = _TestAccountServer(
      'legacy-user',
      'legacy@example.com',
      'Legacy',
    );
    await server.start();
    final store = _MemoryTokenStore();
    store.value = jsonEncode({
      'server': server.uri.toString(),
      'accessToken': 'access-1',
      'refreshToken': 'refresh-1',
      'expiresAt': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
      'user': {
        'id': 'legacy-user',
        'email': 'legacy@example.com',
        'name': 'Legacy',
      },
    });
    final account = AccountController(tokenStore: store);
    addTearDown(() async {
      account.dispose();
      await server.close();
    });

    await account.restore('test-device');

    expect(account.signedIn, isTrue);
    expect(account.accounts, hasLength(1));
    expect(account.activeAccount?.userId, 'legacy-user');
    expect(account.hosts.single.name, 'Legacy');
    final migrated = jsonDecode(store.value!) as Map<String, dynamic>;
    expect(migrated['version'], 2);
    expect((migrated['accounts'] as Map), hasLength(1));
    expect(migrated['active'], account.activeAccountId);
  });

  test('invalid refresh removes only that profile', () async {
    final first = _TestAccountServer('user-a', 'a@example.com', 'Desk A');
    final second = _TestAccountServer('user-b', 'b@example.com', 'Desk B');
    await first.start();
    await second.start();
    final store = _MemoryTokenStore();
    final account = AccountController(server: first.uri, tokenStore: store);
    addTearDown(() async {
      account.dispose();
      await first.close();
      await second.close();
    });

    await account.signInWithPassword(
      'test-device',
      email: 'a@example.com',
      password: 'password-a',
    );
    await account.changeServer(second.uri.toString());
    await account.signInWithPassword(
      'test-device',
      email: 'b@example.com',
      password: 'password-b',
    );
    final firstId = account.accounts
        .singleWhere((profile) => profile.userId == 'user-a')
        .id;

    second.rejectAccess = true;
    second.rejectRefresh = true;
    await account.refreshHosts();

    expect(account.accounts, hasLength(1));
    expect(account.accounts.single.userId, 'user-a');
    expect(account.activeAccountId, firstId);
    expect(account.error, '登录已失效，请重新登录。');
    final persisted = jsonDecode(store.value!) as Map<String, dynamic>;
    expect((persisted['accounts'] as Map), hasLength(1));

    await account.removeAccount(firstId);
    expect(account.signedIn, isFalse);
    expect(account.phase, AccountPhase.signedOut);
    expect(store.value, isNull);
    expect(first.logoutRefreshToken, 'refresh-1');
  });

  test('persists rotated tokens for an independent profile', () async {
    final server = _TestAccountServer(
      'rotating-user',
      'rotate@example.com',
      'Rotate',
    );
    await server.start();
    server.accessToken = 'old-access';
    server.refreshToken = 'old-refresh';
    server.nextAccessToken = 'new-access';
    server.nextRefreshToken = 'new-refresh';
    final store = _MemoryTokenStore();
    store.value = jsonEncode({
      'server': server.uri.toString(),
      'accessToken': 'old-access',
      'refreshToken': 'old-refresh',
      'expiresAt': DateTime.now()
          .add(const Duration(seconds: 1))
          .toIso8601String(),
      'user': {
        'id': 'rotating-user',
        'email': 'rotate@example.com',
        'name': 'Rotate',
      },
    });
    final account = AccountController(tokenStore: store);
    addTearDown(() async {
      account.dispose();
      await server.close();
    });

    await account.restore('test-device');

    expect(account.hosts.single.name, 'Rotate');
    expect(server.listAuthorizations, isNotEmpty);
    expect(server.listAuthorizations.last, 'Bearer new-access');
    expect(store.value, contains('new-refresh'));
    expect(store.value, isNot(contains('old-refresh')));
  });
}
