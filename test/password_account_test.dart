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

void main() {
  test(
    'email login uses the native device identity and stores only tokens',
    () async {
      const password = ' example password ';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Map<String, dynamic>>[];
      String? listAuthorization;
      server.listen((request) async {
        final response = request.response;
        response.headers.contentType = ContentType.json;
        switch ((request.method, request.uri.path)) {
          case ('POST', '/api/v1/auth/login'):
            final body = jsonDecode(
              await utf8.decoder.bind(request).join(),
            ) as Map<String, dynamic>;
            requests.add(body);
            if (body['password'] != password) {
              response.statusCode = HttpStatus.unauthorized;
              response.write(jsonEncode({'error': 'invalid_credentials'}));
            } else {
              response.write(
                jsonEncode({
                  'accessToken': 'test-access',
                  'refreshToken': 'test-refresh',
                  'expiresIn': 3600,
                  'user': {
                    'id': 'test-user',
                    'name': 'Test',
                    'email': 'test@example.com',
                  },
                }),
              );
            }
          case ('GET', '/api/v1/pcs'):
            listAuthorization = request.headers.value(
              HttpHeaders.authorizationHeader,
            );
            response.write(
              jsonEncode({
                'pcs': [
                  {'id': 'test-pc', 'name': 'Streamer', 'online': true},
                ],
              }),
            );
          default:
            response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });

      final store = _MemoryTokenStore();
      final account = AccountController(
        server: Uri.parse('http://127.0.0.1:${server.port}'),
        tokenStore: store,
      );
      addTearDown(account.dispose);

      await account.signInWithPassword(
        'test-device',
        email: 'test@example.com',
        password: 'incorrect',
      );
      expect(account.phase, AccountPhase.signedOut);
      expect(account.error, '邮箱或密码不正确。');
      expect(store.value, isNull);

      await account.signInWithPassword(
        'test-device',
        email: ' test@example.com ',
        password: password,
      );
      expect(requests.last, {
        'email': 'test@example.com',
        'password': password,
        'deviceKind': 'headset',
        'deviceId': 'test-device',
        'deviceName': 'FogShot',
      });
      expect(account.phase, AccountPhase.signedIn);
      expect(account.hosts.single.id, 'test-pc');
      expect(listAuthorization, 'Bearer test-access');
      expect(store.value, contains('test-refresh'));
      expect(store.value, isNot(contains(password)));
    },
  );
}
