import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vaachak_sync/school_api.dart';

/// Separate learner/teacher sessions prevent shared-device identity crossover.
class SchoolConnection {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const key = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const environment = String.fromEnvironment(
    'VAACHAK_ENV',
    defaultValue: 'dev',
  );
  static const localToken = String.fromEnvironment('LOCAL_TEST_ACCESS_TOKEN');
  static bool get localTest =>
      kDebugMode &&
      environment == 'dev' &&
      localToken.isNotEmpty &&
      {'127.0.0.1', 'localhost'}.contains(Uri.tryParse(url)?.host);
  static bool get configured =>
      (url.startsWith('https://') && key.isNotEmpty) || localTest;
  final String role;
  late final SupabaseClient client;
  final http.Client httpClient = http.Client();
  late final SchoolApi api;
  SchoolConnection(this.role) {
    if (!configured) throw StateError('This app is not connected to a school');
    client = SupabaseClient(
      url,
      key.isEmpty ? 'local-test' : key,
      accessToken: localTest ? () async => localToken : null,
    );
    api = SchoolApi(
      Uri.parse(url),
      key,
      () async => localTest
          ? localToken
          : client.auth.currentSession?.accessToken ?? '',
      httpClient,
      environment: environment,
      allowLocalTest: localTest,
      accountScope: () => signedIn ? userId : 'signed-out',
    );
  }
  bool get signedIn => localTest || client.auth.currentSession != null;
  String get userId => localTest
      ? (jsonDecode(
                  utf8.decode(
                    base64Url.decode(
                      base64Url.normalize(localToken.split('.')[1]),
                    ),
                  ),
                )
                as Map)['sub']
            as String
      : client.auth.currentUser!.id;
  String get _storage => 'school.auth:$url:$environment:$role';
  Future<void> restore() async {
    if (localTest) return;
    final value = await const FlutterSecureStorage().read(key: _storage);
    if (value != null) {
      try {
        await client.auth.recoverSession(value);
      } catch (_) {
        await const FlutterSecureStorage().delete(key: _storage);
      }
    }
  }

  Future<void> signIn(String email, String password) async {
    if (email.trim().isEmpty || password.isEmpty) {
      throw ArgumentError('Email and password are required');
    }
    await client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    final session = client.auth.currentSession;
    if (session == null) throw StateError('Sign-in did not create a session');
    try {
      await const FlutterSecureStorage().write(
        key: _storage,
        value: jsonEncode(session.toJson()),
      );
    } catch (_) {
      await client.auth.signOut(scope: SignOutScope.local);
      rethrow;
    }
  }

  Future<void> signOut() async {
    if (!localTest) {
      // Remove the local persisted session even when remote logout is offline.
      await const FlutterSecureStorage().delete(key: _storage);
      await client.auth.signOut(scope: SignOutScope.local);
    }
  }

  Future<void> close() async {
    httpClient.close();
    await client.dispose();
  }
}
