import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vaachak_sync/school_api.dart';
import 'package:vaachak_sync/vaachak_sync.dart';

void main() {
  test(
    'school requests reject public cleartext and unconfigured environments',
    () {
      final client = MockClient((_) async => http.Response('{}', 200));
      expect(
        () => SchoolApi(
          Uri.parse('http://example.com'),
          'k',
          () async => 'token',
          client,
          allowLocalTest: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => SchoolApi(
          Uri.parse('http://127.0.0.1'),
          'k',
          () async => 'token',
          client,
          environment: 'prod',
          allowLocalTest: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => SchoolApi(
          Uri.parse('https://example.com'),
          'k',
          () async => 'token',
          client,
          environment: 'other',
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'school RPC uses scoped schemas and never redirects credentials',
    () async {
      final client = MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(request.headers['Content-Profile'], 'qa');
        expect(request.headers['Accept-Profile'], 'qa');
        expect(request.url.path, '/rest/v1/rpc/pull_changes');
        expect(jsonDecode(request.body), {'after_seq': 42});
        return http.Response('{"interventions":[]}', 200);
      });
      final api = SchoolApi(
        Uri.parse('https://school.example'),
        'public',
        () async => 'token',
        client,
        environment: 'qa',
        accountScope: () => 'teacher-a',
      );
      expect(
        (await api.rpc('pull_changes', {'after_seq': 42}))['interventions'],
        isEmpty,
      );
      expect(api.scope, contains('teacher-a'));
    },
  );
  test(
    'unauthenticated, oversized and failed school responses remain errors',
    () async {
      var called = false;
      final noAuth = SchoolApi(
        Uri.parse('https://school.example'),
        'public',
        () async => '',
        MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(noAuth.rpc('sync_pairings'), throwsStateError);
      expect(called, isFalse);
      final oversized = SchoolApi(
        Uri.parse('https://school.example'),
        'public',
        () async => 'token',
        MockClient(
          (_) async => http.Response('x' * (4 * 1024 * 1024 + 1), 200),
        ),
      );
      await expectLater(oversized.rpc('pull_changes'), throwsFormatException);
      final denied = SchoolApi(
        Uri.parse('https://school.example'),
        'public',
        () async => 'token',
        MockClient((_) async => http.Response('denied', 403)),
      );
      await expectLater(denied.rpc('sync_pairings'), throwsStateError);
    },
  );
  test(
    'LAN sender never connects to public, DNS or credential-bearing URLs',
    () async {
      for (final target in [
        'http://8.8.8.8/vbundle',
        'http://school.example/vbundle',
        'http://user:pass@192.168.1.1/vbundle',
        'https://192.168.1.1/vbundle',
      ]) {
        await expectLater(
          sendHotspot(Uri.parse(target), Uint8List(1)),
          throwsArgumentError,
        );
      }
    },
  );
}
