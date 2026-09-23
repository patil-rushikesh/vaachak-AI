import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:vaachak_packs/vaachak_packs.dart';

class NoDownload implements PackSource {
  int reads = 0;
  @override
  Stream<List<int>> read(String path, int offset) async* {
    reads++;
    throw StateError('Storage check must happen before downloading');
  }
}

void main() {
  test(
    'installation reserves 500 MB beyond both download and activated copy',
    () async {
      final root = await Directory.systemTemp.createTemp('reserve-');
      addTearDown(() => root.delete(recursive: true));
      final key = await Ed25519().newKeyPair();
      final data = <String, dynamic>{
        'packId': 'large.content',
        'version': '1.0.0',
        'kind': 'content',
        'keyId': 'school',
        'minTier': 'C',
        'appVersionRange': '>=0.1.0 <1.0.0',
        'sizeBytes': 400000000,
        'files': [
          {'path': 'content.bin', 'sizeBytes': 400000000, 'sha256': '0' * 64},
        ],
      };
      data['signature'] = base64Encode(
        (await Ed25519().sign(
          utf8.encode(canonicalJson(data)),
          keyPair: key,
        )).bytes,
      );
      final manager = PackManager(
        root: root,
        trustedKeys: {'school': await key.extractPublicKey()},
        device: const DeviceCapabilities(
          ramBytes: 4000000000,
          freeBytes: 1100000000,
          androidSdk: 29,
          arm64: true,
        ),
        appVersion: Version(0, 1, 0),
      );
      addTearDown(manager.dispose);
      final source = NoDownload();
      await expectLater(
        manager.install(PackManifest(data), source),
        throwsA(isA<FileSystemException>()),
      );
      expect(source.reads, 0);
      expect(await root.list().toList(), isEmpty);
    },
  );
}
