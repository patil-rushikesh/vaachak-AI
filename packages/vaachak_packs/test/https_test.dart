import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vaachak_packs/vaachak_packs.dart';

void main() {
  test('HTTPS resume requires partial response and matching range', () async {
    for (final response in [
      http.Response('rest', 200),
      http.Response('x', 206, headers: {'content-range': 'bytes 3-6/7'}),
      http.Response('rest', 206, headers: {'content-range': 'bytes 3-6/5'}),
      http.Response('rest', 206, headers: {'content-range': 'bytes 2-5/6'}),
      http.Response(
        'rest',
        302,
        headers: {'location': 'https://other.example/data'},
      ),
    ]) {
      final client = MockClient((request) async {
        expect(request.headers['Range'], 'bytes=3-');
        expect(request.followRedirects, isFalse);
        return response;
      });
      final source = HttpsPackSource(
        Uri.parse('https://school.example/pack/'),
        client,
      );
      await expectLater(
        source.read('data', 3).toList(),
        throwsA(isA<Exception>()),
      );
      client.close();
    }
  });
  test('valid HTTPS range emits remaining bytes', () async {
    final client = MockClient(
      (request) async =>
          http.Response('ture', 206, headers: {'content-range': 'bytes 3-6/7'}),
    );
    final source = HttpsPackSource(
      Uri.parse('https://school.example/pack/'),
      client,
    );
    expect(await source.read('data', 3).expand((x) => x).toList(), [
      116,
      117,
      114,
      101,
    ]);
    client.close();
  });
}
