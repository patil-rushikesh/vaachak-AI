import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Shared by native learners and the web teacher portal. No service key is used.
class SchoolApi {
  final Uri endpoint;
  final String publicKey, environment;
  final Future<String> Function() token;
  final http.Client client;
  final String Function()? accountScope;
  SchoolApi(
    this.endpoint,
    this.publicKey,
    this.token,
    this.client, {
    this.environment = 'dev',
    this.accountScope,
    bool allowLocalTest = false,
  }) {
    if (!{'dev', 'qa', 'prod'}.contains(environment) ||
        (endpoint.scheme != 'https' &&
            !(allowLocalTest &&
                environment == 'dev' &&
                endpoint.scheme == 'http' &&
                {'localhost', '127.0.0.1'}.contains(endpoint.host)))) {
      throw ArgumentError('A secure school endpoint is required');
    }
  }
  String get scope =>
      '${endpoint.origin}:$environment:${accountScope?.call() ?? 'device'}';
  Future<dynamic> request(String path, {Map<String, dynamic>? body}) async {
    final access = await token();
    if (access.isEmpty) throw StateError('Sign in to your school first');
    final req =
        http.Request(
            body == null ? 'GET' : 'POST',
            endpoint.resolve('/rest/v1/$path'),
          )
          ..followRedirects = false
          ..headers.addAll({
            'apikey': publicKey,
            'Authorization': 'Bearer $access',
            'Content-Type': 'application/json',
            'Accept-Profile': environment,
            'Content-Profile': environment,
          });
    if (body != null) req.body = jsonEncode(body);
    final response = await client
        .send(req)
        .timeout(const Duration(seconds: 20));
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (bytes.length + chunk.length > 4 * 1024 * 1024) {
        throw const FormatException('School response too large');
      }
      bytes.addAll(chunk);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('School request failed (${response.statusCode})');
    }
    return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
  }

  Future<dynamic> rpc(String name, [Map<String, dynamic> args = const {}]) =>
      request('rpc/$name', body: args);
}
