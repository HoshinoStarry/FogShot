import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fogshot/account_panel.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  AccountPanel accountPanel({
    Future<String?> Function(String email, String password)? onPasswordSignIn,
    bool signedIn = false,
    bool working = false,
    String code = '',
    Uri? verificationUrl,
    List<AccountTarget> hosts = const [],
    VoidCallback? onSignIn,
  }) => AccountPanel(
    server: Uri.parse('https://rincast.com'),
    signedIn: signedIn,
    working: working,
    enabled: true,
    name: signedIn ? 'Test account' : '',
    code: code,
    verificationUrl: verificationUrl,
    error: '',
    hosts: hosts,
    onSignIn: onSignIn ?? () {},
    onPasswordSignIn: onPasswordSignIn ?? (_, _) async => null,
    onCancel: () {},
    onSignOut: () {},
    onRefresh: () {},
    onConnect: (_) {},
    onServerChanged: (_) async => null,
  );

  testWidgets('validates and submits the email and password dialog', (
    tester,
  ) async {
    String? submittedEmail;
    String? submittedPassword;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: accountPanel(
            onPasswordSignIn: (email, password) async {
              submittedEmail = email;
              submittedPassword = password;
              return null;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('邮箱密码登录'));
    await tester.pumpAndSettle();
    expect(find.text('邮箱密码登录'), findsNWidgets(2));

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    final passwordField = tester.widget<TextField>(
      find.descendant(of: fields.at(1), matching: find.byType(TextField)),
    );
    expect(passwordField.obscureText, isTrue);

    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pump();
    expect(find.text('请输入邮箱。'), findsOneWidget);
    expect(find.text('请输入密码。'), findsOneWidget);
    expect(submittedEmail, isNull);

    await tester.enterText(fields.at(0), ' user@example.com ');
    await tester.enterText(fields.at(1), 'secret');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();

    expect(submittedEmail, 'user@example.com');
    expect(submittedPassword, 'secret');
    expect(find.text('邮箱密码登录'), findsOneWidget);
  });

  testWidgets('keeps the dialog open and shows callback errors', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: accountPanel(onPasswordSignIn: (_, _) async => '邮箱或密码错误。'),
        ),
      ),
    );

    await tester.tap(find.text('邮箱密码登录'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'user@example.com');
    await tester.enterText(fields.at(1), 'incorrect');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();

    expect(find.text('邮箱或密码错误。'), findsOneWidget);
    expect(find.text('邮箱密码登录'), findsNWidgets(2));
  });

  testWidgets('password dialog fits a narrow viewport', (tester) async {
    await tester.binding.setSurfaceSize(const Size(280, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: accountPanel())));

    await tester.tap(find.text('邮箱密码登录'));
    await tester.pumpAndSettle();

    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('expands automatically when account work starts', (tester) async {
    var working = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return accountPanel(working: working);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('RinCast 账户'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('设备码登录'), findsNothing);

    update(() => working = true);
    await tester.pump();
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets(
    'device sign-in opens HTTPS verification once and can be reopened',
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

      var signedIn = false;
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
                return accountPanel(
                  signedIn: signedIn,
                  working: working,
                  code: code,
                  verificationUrl: verificationUrl,
                  onSignIn: () => signInCalls++,
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('设备码登录'));
      await tester.pump();
      expect(signInCalls, 1);

      final url = Uri.parse('https://rincast.com/device?user_code=ABCD-EFGH');
      update(() {
        working = true;
        code = 'ABCD-EFGH';
        verificationUrl = url;
      });
      await tester.pump();
      await tester.pump();
      expect(opened, [url.toString()]);
      expect(find.text('重新打开浏览器'), findsOneWidget);

      update(() => working = true);
      await tester.pump();
      expect(opened, [url.toString()]);

      await tester.tap(find.text('重新打开浏览器'));
      await tester.pump();
      await tester.pump();
      expect(opened, [url.toString(), url.toString()]);
    },
  );

  testWidgets('existing approval does not open until explicitly requested', (
    tester,
  ) async {
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

    final url = Uri.parse('https://rincast.com/device?user_code=RESTORED');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: accountPanel(
            working: true,
            code: 'RESTORED',
            verificationUrl: url,
          ),
        ),
      ),
    );

    expect(opened, isEmpty);
    await tester.tap(find.text('打开浏览器'));
    await tester.pump();
    await tester.pump();
    expect(opened, [url.toString()]);
  });
}
