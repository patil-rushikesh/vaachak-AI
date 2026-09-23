import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:vaachak_packs/vaachak_packs.dart';
import 'package:vaachak_packs/catalog.dart';

void main() {
  late Directory root;
  late PackManager manager;
  late SimpleKeyPair key;
  late Map<String, dynamic> manifest;
  final now = DateTime.utc(2026, 9, 23);
  final payload = utf8.encode('reviewed fixture');
  final uri = Uri.parse('https://school.example/catalog.json');
  Future<Map<String, dynamic>> sign(Map<String, dynamic> data) async => {
    ...data,
    'signature': base64Encode(
      (await Ed25519().sign(
        utf8.encode(canonicalJson(data)),
        keyPair: key,
      )).bytes,
    ),
  };
  Future<String> catalog({
    int sequence = 1,
    DateTime? expires,
    Map<String, dynamic>? pack,
  }) async => jsonEncode(
    await sign({
      'schemaVersion': 1,
      'sequence': sequence,
      'keyId': 'school',
      'issuedAt': now.toIso8601String(),
      'expiresAt': (expires ?? now.add(const Duration(days: 2)))
          .toIso8601String(),
      'packs': [
        {
          'baseUrl': 'https://school.example/packs/1.0.0/',
          'manifest': pack ?? manifest,
        },
      ],
    }),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('catalog-');
    key = await Ed25519().newKeyPair();
    manager = PackManager(
      root: root,
      trustedKeys: {'school': await key.extractPublicKey()},
      device: const DeviceCapabilities(
        ramBytes: 4000000000,
        freeBytes: 4000000000,
        androidSdk: 29,
        arm64: true,
      ),
      appVersion: Version(0, 1, 0),
    );
    manifest = await sign({
      'packId': 'test.content',
      'version': '1.0.0',
      'kind': 'content',
      'minTier': 'C',
      'keyId': 'school',
      'appVersionRange': '>=0.1.0 <1.0.0',
      'sizeBytes': payload.length,
      'files': [
        {
          'path': 'content.json',
          'sizeBytes': payload.length,
          'sha256': digest.sha256.convert(payload).toString(),
        },
      ],
    });
  });
  tearDown(() async {
    await manager.dispose();
    await root.delete(recursive: true);
  });
  test(
    'verified catalog installs exact signed bytes through HTTPS source',
    () async {
      final body = await catalog();
      final client = MockClient((request) async {
        expect(request.followRedirects, isFalse);
        return request.url == uri
            ? http.Response(body, 200)
            : http.Response.bytes(payload, 200);
      });
      addTearDown(client.close);
      final updates = await PackCatalog(
        manager,
        client,
      ).check(uri, {}, now: now);
      expect(updates.single.manifest.id, 'test.content');
      final installed = await manager.install(
        updates.single.manifest,
        HttpsPackSource(updates.single.base, client),
      );
      expect(
        await File('${installed.path}/content.json').readAsBytes(),
        payload,
      );
      expect(
        await PackCatalog(
          manager,
          client,
        ).check(uri, {'test.content': '1.0.0'}, now: now),
        isEmpty,
      );
      expect(
        await PackCatalog(
          manager,
          client,
        ).check(uri, {'test.content': '2.0.0'}, now: now),
        isEmpty,
      );
    },
  );
  test('replay protection survives reopening the catalog service', () async {
    var body = await catalog(sequence: 2);
    final client = MockClient((_) async => http.Response(body, 200));
    addTearDown(client.close);
    await PackCatalog(manager, client).check(uri, {}, now: now);
    body = await catalog(sequence: 1);
    await expectLater(
      PackCatalog(manager, client).check(uri, {}, now: now),
      throwsStateError,
    );
    body = await catalog(
      sequence: 2,
      expires: now.add(const Duration(days: 3)),
    );
    await expectLater(
      PackCatalog(manager, client).check(uri, {}, now: now),
      throwsStateError,
    );
  });
  test('expiry and catalog signature tampering fail closed', () async {
    var body = await catalog(expires: now);
    final client = MockClient((_) async => http.Response(body, 200));
    addTearDown(client.close);
    await expectLater(
      PackCatalog(manager, client).check(uri, {}, now: now),
      throwsFormatException,
    );
    body = (await catalog()).replaceFirst('test.content', 'evil.content');
    await expectLater(
      PackCatalog(manager, client).check(uri, {}, now: now),
      throwsStateError,
    );
    expect(await root.list().toList(), isEmpty);
  });
  test('a signed catalog cannot authorize an unsigned pack', () async {
    final body = await catalog(pack: {...manifest, 'version': '2.0.0'});
    final client = MockClient((_) async => http.Response(body, 200));
    addTearDown(client.close);
    await expectLater(
      PackCatalog(manager, client).check(uri, {}, now: now),
      throwsStateError,
    );
  });
  test(
    'redirects oversized responses and insecure URLs are rejected',
    () async {
      var body = '';
      var status = 302;
      final client = MockClient((_) async => http.Response(body, status));
      addTearDown(client.close);
      final service = PackCatalog(manager, client);
      await expectLater(
        service.check(Uri.parse('http://school.example/catalog.json'), {}),
        throwsArgumentError,
      );
      await expectLater(
        service.check(uri, {}, now: now),
        throwsA(isA<HttpException>()),
      );
      status = 200;
      body = 'x' * 1048577;
      await expectLater(
        service.check(uri, {}, now: now),
        throwsFormatException,
      );
    },
  );
}
