import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:vaachak_packs/vaachak_packs.dart';

void main() {
  test('tier thresholds respect memory storage OS and thermal limits', () {
    expect(
      const DeviceCapabilities(
        ramBytes: 4000000000,
        freeBytes: 2000000000,
        androidSdk: 26,
        arm64: true,
      ).tier,
      DeviceTier.b,
    );
    expect(
      const DeviceCapabilities(
        ramBytes: 6000000000,
        freeBytes: 4000000000,
        androidSdk: 29,
        arm64: true,
      ).tier,
      DeviceTier.a,
    );
    expect(
      const DeviceCapabilities(
        ramBytes: 6000000000,
        freeBytes: 4000000000,
        androidSdk: 29,
        arm64: true,
        thermalLimited: true,
      ).tier,
      DeviceTier.b,
    );
    expect(
      () => const DeviceCapabilities(
        ramBytes: 1000000000,
        freeBytes: 4000000000,
        androidSdk: 29,
        arm64: true,
      ).tier,
      throwsStateError,
    );
  });
  test('signed installation is atomic and detects changed payloads', () async {
    final root = await Directory.systemTemp.createTemp('vaachak-pack-test-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source');
    await source.create();
    final data = utf8.encode('Reviewed test content');
    await File('${source.path}/content.json').writeAsBytes(data);
    final key = await Ed25519().newKeyPair(),
        public = await (await Ed25519().newKeyPair()).extractPublicKey();
    final map = <String, dynamic>{
      'packId': 'test.core',
      'kind': 'core',
      'version': '1.0.0',
      'keyId': 'release',
      'minTier': 'C',
      'appVersionRange': '>=0.1.0 <2.0.0',
      'sizeBytes': data.length,
      'files': [
        {
          'path': 'content.json',
          'sizeBytes': data.length,
          'sha256': sha256.convert(data).toString(),
        },
      ],
    };
    map['signature'] = base64Encode(
      (await Ed25519().sign(
        utf8.encode(canonicalJson(map)),
        keyPair: key,
      )).bytes,
    );
    final manager = PackManager(
      root: Directory('${root.path}/installed'),
      trustedKeys: {'release': await key.extractPublicKey()},
      device: const DeviceCapabilities(
        ramBytes: 4000000000,
        freeBytes: 4000000000,
        androidSdk: 29,
        arm64: true,
      ),
      appVersion: Version(0, 1, 0),
    );
    addTearDown(manager.dispose);
    final manifest = PackManifest(map),
        installed = await manager.install(
          PackManifest(map),
          DirectoryPackSource(source),
        );
    expect(await File('${installed.path}/content.json').readAsBytes(), data);
    await File('${installed.path}/content.json').writeAsString('tampered');
    await expectLater(
      manager.verifyInstalled(manifest, installed),
      throwsStateError,
    );
    final untrusted = PackManager(
      root: root,
      trustedKeys: {'release': public},
      device: manager.device,
      appVersion: Version(0, 1, 0),
    );
    addTearDown(untrusted.dispose);
    await expectLater(untrusted.verifyManifest(manifest), throwsStateError);
    final traversal = {
      ...map,
      'files': [
        {
          'path': '../escape',
          'sizeBytes': data.length,
          'sha256': sha256.convert(data).toString(),
        },
      ],
    };
    expect(() => PackManifest(traversal), throwsFormatException);
  });
}
