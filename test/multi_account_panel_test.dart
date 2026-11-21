import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fogshot/account.dart';
import 'package:fogshot/account_panel.dart';
import 'package:material_ui/material_ui.dart';

AccountHost _host(String name) => AccountHost(
  id: 'pc-1',
  name: name,
  gpu: '',
  os: '',
  version: '',
  online: true,
  busy: false,
  lastSeenAt: null,
);

AccountProfile _profile({
  required String id,
  required String name,
  required String email,
  required bool active,
  required List<AccountHost> hosts,
  bool loading = false,
  String? error,
}) => AccountProfile(
  id: id,
  server: Uri.parse('https://$id.example.com'),
  user: AccountUser(id: 'rin-$id', email: email, name: name, createdAt: null),
  active: active,
  phase: AccountPhase.signedIn,
  hosts: hosts,
  loadingHosts: loading,
  error: error,
);

void main() {
  testWidgets('shows every profile device and routes with account and PC id', (
    tester,
  ) async {
    final alpha = _profile(
      id: 'alpha',
      name: 'Alpha Profile',
      email: 'alpha@example.com',
      active: true,
      hosts: [_host('Alpha Desk')],
    );
    final beta = _profile(
      id: 'beta',
      name: 'Beta Profile',
      email: 'beta@example.com',
      active: false,
      hosts: [_host('Beta Desk')],
    );
    final connected = <(String, String)>[];
    String? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPanel(
            server: Uri.parse('https://rincast.com'),
            signedIn: true,
            working: false,
            enabled: true,
            name: alpha.name,
            code: '',
            verificationUrl: null,
            error: '',
            hosts: const [],
            accounts: [alpha, beta],
            activeAccountId: alpha.id,
            onSignIn: () {},
            onPasswordSignIn: (_, _) async => null,
            onCancel: () {},
            onSignOut: () {},
            onRefresh: () {},
            onConnect: (_) {},
            onServerChanged: (_) async => null,
            onSelectAccount: (id) => selected = id,
            onRemoveAccount: (_) async => null,
            onConnectAccount: (accountId, pcId) =>
                connected.add((accountId, pcId)),
          ),
        ),
      ),
    );

    expect(find.text('Alpha Desk'), findsOneWidget);
    expect(find.text('Beta Desk'), findsOneWidget);
    expect(find.text('2 个账户 · 2/2 台设备在线'), findsOneWidget);
    expect(find.text('设备码'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);

    await tester.tap(find.text('Beta Desk'));
    expect(connected, [('beta', 'pc-1')]);

    await tester.tap(find.text('Beta Profile'));
    await tester.pump();
    expect(selected, 'beta');
  });

  testWidgets('removes one named profile after confirmation', (tester) async {
    final alpha = _profile(
      id: 'alpha',
      name: 'Alpha Profile',
      email: 'alpha@example.com',
      active: true,
      hosts: [_host('Alpha Desk')],
    );
    final removed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPanel(
            server: Uri.parse('https://rincast.com'),
            signedIn: true,
            working: false,
            enabled: true,
            name: alpha.name,
            code: '',
            verificationUrl: null,
            error: '',
            hosts: const [],
            accounts: [alpha],
            activeAccountId: alpha.id,
            onSignIn: () {},
            onPasswordSignIn: (_, _) async => null,
            onCancel: () {},
            onSignOut: () {},
            onRefresh: () {},
            onConnect: (_) {},
            onServerChanged: (_) async => null,
            onRemoveAccount: (accountId) async {
              removed.add(accountId);
              return '移除时保留其他账户失败。';
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除账户'));
    await tester.pumpAndSettle();
    expect(
      find.text('将从此设备移除“Alpha Profile”及其登录令牌。其他账户的设备不受影响。'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await tester.pumpAndSettle();

    expect(removed, ['alpha']);
    expect(find.text('移除时保留其他账户失败。'), findsOneWidget);
  });

  testWidgets('keeps grouped account controls compact on a narrow panel', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final accounts = [
      _profile(
        id: 'alpha',
        name: 'A Long Alpha Account Name',
        email: 'alpha@example.com',
        active: true,
        hosts: [_host('Alpha Desk')],
      ),
      _profile(
        id: 'beta',
        name: 'A Long Beta Account Name',
        email: 'beta@example.com',
        active: false,
        hosts: [_host('Beta Desk')],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPanel(
            server: Uri.parse('https://rincast.com'),
            signedIn: true,
            working: false,
            enabled: true,
            name: accounts.first.name,
            code: '',
            verificationUrl: null,
            error: '',
            hosts: const [],
            accounts: accounts,
            activeAccountId: accounts.first.id,
            onSignIn: () {},
            onPasswordSignIn: (_, _) async => null,
            onCancel: () {},
            onSignOut: () {},
            onRefresh: () {},
            onConnect: (_) {},
            onServerChanged: (_) async => null,
            onConnectAccount: (_, _) {},
          ),
        ),
      ),
    );

    expect(find.text('Alpha Desk'), findsOneWidget);
    expect(find.text('Beta Desk'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'opens approval for a second account while another is signed in',
    (tester) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final opened = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'launch') return null;
            opened.add((call.arguments as Map)['url'] as String);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final existing = _profile(
        id: 'existing',
        name: 'Existing Profile',
        email: 'existing@example.com',
        active: true,
        hosts: [_host('Existing Desk')],
      );
      var working = false;
      var code = '';
      Uri? verificationUrl;
      var signInCalls = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return AccountPanel(
                  server: Uri.parse('https://rincast.com'),
                  signedIn: true,
                  working: working,
                  enabled: true,
                  name: existing.name,
                  code: code,
                  verificationUrl: verificationUrl,
                  error: '',
                  hosts: const [],
                  accounts: [existing],
                  activeAccountId: existing.id,
                  onSignIn: () {
                    signInCalls++;
                    update(() => working = true);
                  },
                  onPasswordSignIn: (_, _) async => null,
                  onCancel: () {},
                  onSignOut: () {},
                  onRefresh: () {},
                  onConnect: (_) {},
                  onServerChanged: (_) async => null,
                  onConnectAccount: (_, _) {},
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('设备码'));
      await tester.pump();
      expect(signInCalls, 1);

      final url = Uri.parse('https://rincast.com/link?code=SECOND');
      update(() {
        code = 'SECOND';
        verificationUrl = url;
      });
      await tester.pump();
      await tester.pump();

      expect(opened, [url.toString()]);
    },
  );
}
