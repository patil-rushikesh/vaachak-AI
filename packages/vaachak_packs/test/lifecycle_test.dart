import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:vaachak_packs/vaachak_packs.dart';

void main() {
  late Directory root, source;
  late SimpleKeyPair key;
  late PackManager manager;
  Future<PackManifest> manifest(
    String version, {
    Map<String, dynamic>? runtime,
  }) async {
    final bytes = utf8.encode('fixture');
    final map = <String, dynamic>{
      'packId': 'fixture',
      'kind': 'content',
      'version': version,
      'minTier': 'C',
      'keyId': 'test',
      'appVersionRange': '^0.1.0',
      'sizeBytes': bytes.length,
      'files': [
        {
          'path': 'data',
          'sizeBytes': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        },
      ],
      'runtime': ?runtime,
    };
    map['signature'] = base64Encode(
      (await Ed25519().sign(
        utf8.encode(canonicalJson(map)),
        keyPair: key,
      )).bytes,
    );
    return PackManifest(map);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pack-lifecycle-');
    source = await Directory('${root.path}/source').create();
    await File('${source.path}/data').writeAsString('fixture');
    key = await Ed25519().newKeyPair();
    manager = PackManager(
      root: Directory('${root.path}/packs'),
      trustedKeys: {'test': await key.extractPublicKey()},
      device: const DeviceCapabilities(
        ramBytes: 6000000000,
        freeBytes: 4000000000,
        androidSdk: 29,
        arm64: true,
      ),
      appVersion: Version(0, 1, 0),
    );
  });
  tearDown(() async {
    await manager.dispose();
    await root.delete(recursive: true);
  });
  test('install refreshes storage capabilities before writing', () async {
    final refreshed = PackManager(
      root: manager.root,
      trustedKeys: manager.trustedKeys,
      device: manager.device,
      appVersion: manager.appVersion,
      refreshDevice: () async => const DeviceCapabilities(
        ramBytes: 6000000000,
        freeBytes: 100,
        androidSdk: 29,
        arm64: true,
      ),
    );
    addTearDown(refreshed.dispose);
    await expectLater(
      refreshed.install(await manifest('1.0.0'), DirectoryPackSource(source)),
      throwsStateError,
    );
    expect(await manager.root.exists(), isFalse);
  });
  test('interrupted stream resumes at exact saved offset', () async {
    final m = await manifest('1.0.0');
    final flaky = _InterruptedSource();
    await expectLater(manager.install(m, flaky), throwsStateError);
    final installed = await manager.install(m, flaky);
    expect(flaky.offsets, [0, 3]);
    expect(await File('${installed.path}/data').readAsString(), 'fixture');
  });
  test('overflow never activates and a clean retry succeeds', () async {
    final m = await manifest('1.0.0');
    await expectLater(
      manager.install(m, _OverflowSource()),
      throwsFormatException,
    );
    expect(await File('${manager.root.path}/fixture/active').exists(), isFalse);
    await manager.install(m, DirectoryPackSource(source));
  });
  test('same version cannot replace already signed manifest', () async {
    final m = await manifest('1.0.0');
    await manager.install(m, DirectoryPackSource(source));
    final changed = jsonDecode(jsonEncode(m.json)) as Map<String, dynamic>;
    changed['appVersionRange'] = '>=0.1.0 <3.0.0';
    changed.remove('signature');
    changed['signature'] = base64Encode(
      (await Ed25519().sign(
        utf8.encode(canonicalJson(changed)),
        keyPair: key,
      )).bytes,
    );
    await expectLater(
      manager.install(PackManifest(changed), DirectoryPackSource(source)),
      throwsStateError,
    );
  });
  test(
    'activation remembers previous and rollback verifies it again',
    () async {
      await manager.install(
        await manifest('1.0.0'),
        DirectoryPackSource(source),
      );
      await manager.install(
        await manifest('1.1.0'),
        DirectoryPackSource(source),
      );
      await manager.rollback('fixture');
      expect(
        await File('${manager.root.path}/fixture/active').readAsString(),
        '1.0.0',
      );
      await File(
        '${manager.root.path}/fixture/1.1.0/data',
      ).writeAsString('changed');
      await expectLater(manager.rollback('fixture'), throwsStateError);
      expect(
        await File('${manager.root.path}/fixture/active').readAsString(),
        '1.0.0',
      );
    },
  );
  test('unsigned additional native-runtime inputs are rejected', () async {
    final m = await manifest('1.0.0');
    final target = await manager.install(m, DirectoryPackSource(source));
    await File('${target.path}/extra').writeAsString('unsigned');
    await expectLater(manager.verifyInstalled(m, target), throwsStateError);
  });
  test('installed symlinks are rejected even with valid contents', () async {
    final m = await manifest('1.0.0');
    final target = await manager.install(m, DirectoryPackSource(source));
    await File('${target.path}/data').delete();
    await Link('${target.path}/data').create('${source.path}/data');
    await expectLater(manager.verifyInstalled(m, target), throwsStateError);
  });
  test('runtime must use supported kind and signed files', () async {
    await expectLater(
      manifest(
        '1.0.0',
        runtime: {
          'explainer': {'type': 'litertlm', 'model': 'data'},
        },
      ),
      throwsFormatException,
    );
    await expectLater(
      manifest('1.0.0', runtime: {'unknown': {}}),
      throwsFormatException,
    );
  });
  test('signed manifest cannot be mutated after verification', () async {
    final m = await manifest('1.0.0');
    expect(() => m.json['version'] = '2.0.0', throwsUnsupportedError);
    expect(() => (m.json['files'] as List).clear(), throwsUnsupportedError);
  });
}

class _InterruptedSource implements PackSource {
  final offsets = <int>[];
  @override
  Stream<List<int>> read(String path, int offset) async* {
    offsets.add(offset);
    if (offset == 0) {
      yield utf8.encode('fix');
      throw StateError('Disconnected');
    }
    yield utf8.encode('fixture').sublist(offset);
  }
}

class _OverflowSource implements PackSource {
  @override
  Stream<List<int>> read(String path, int offset) async* {
    yield utf8.encode('fixture overflow');
  }
}
