import 'package:flutter_test/flutter_test.dart';
import 'package:fogshot/account_panel.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  AccountPanel accountPanel({
    Future<String?> Function(String email, String password)? onPasswordSignIn,
  }) => AccountPanel(
    server: Uri.parse('https://rincast.com'),
    signedIn: false,
    working: false,
    enabled: true,
    name: '',
    code: '',
    verificationUrl: null,
    error: '',
    hosts: const [],
    onSignIn: () {},
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
}
