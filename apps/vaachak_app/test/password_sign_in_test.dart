import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaachak_app/password_sign_in.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    Future<void> Function(String, String) signIn,
  ) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PasswordSignIn(label: 'School email', onSignIn: signIn),
      ),
    ),
  );
  testWidgets('requires credentials and never offers OTP', (tester) async {
    var calls = 0;
    await mount(tester, (_, _) async {
      calls++;
    });
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
    expect(calls, 0);
    expect(find.text('Send sign-in code'), findsNothing);
  });
  testWidgets(
    'preserves password whitespace, blocks duplicate requests, clears on success',
    (tester) async {
      final done = Completer<void>();
      var calls = 0;
      await mount(tester, (email, password) async {
        calls++;
        expect(email, 'teacher@example.test');
        expect(password, ' password with spaces ');
        await done.future;
      });
      await tester.enterText(
        find.byType(TextFormField).at(0),
        ' teacher@example.test ',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        ' password with spaces ',
      );
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(calls, 1);
      done.complete();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).at(1))
            .controller!
            .text,
        isEmpty,
      );
    },
  );
  testWidgets(
    'authentication failure is generic and supports retry without email',
    (tester) async {
      await mount(tester, (_, _) async {
        throw StateError('account-secret must not leak');
      });
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'teacher@example.test',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'wrong');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Unable to sign in.'), findsOneWidget);
      expect(find.textContaining('account-secret'), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    },
  );
}
