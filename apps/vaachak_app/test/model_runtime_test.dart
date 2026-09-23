import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:vaachak_packs/vaachak_packs.dart';
import 'package:vaachak_app/model_runtime.dart';

void main() {
  test('verified speech selection and heavyweight runtime lease', () async {
    final temp = await Directory.systemTemp.createTemp('runtime-test-');
    addTearDown(() => temp.delete(recursive: true));
    final source = await Directory(
      '${temp.path}/source/phonemes',
    ).create(recursive: true);
    await File('${source.path}/data').writeAsString('fixture');
    final bytes = utf8.encode('fixture'), key = await Ed25519().newKeyPair();
    final map = <String, dynamic>{
      'packId': 'speech.test',
      'version': '1.0.0',
      'kind': 'speech',
      'keyId': 'test',
      'minTier': 'C',
      'appVersionRange': '^0.1.0',
      'sizeBytes': bytes.length,
      'files': [
        {
          'path': 'phonemes/data',
          'sizeBytes': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        },
      ],
      'runtime': {
        'asr': {
          'type': 'whisper',
          'tokens': 'phonemes/data',
          'encoder': 'phonemes/data',
          'decoder': 'phonemes/data',
        },
        'tts': {
          'type': 'vits',
          'tokens': 'phonemes/data',
          'model': 'phonemes/data',
          'dataDir': 'phonemes',
        },
      },
    };
    map['signature'] = base64Encode(
      (await Ed25519().sign(
        utf8.encode(canonicalJson(map)),
        keyPair: key,
      )).bytes,
    );
    final manager = PackManager(
      root: Directory('${temp.path}/packs'),
      trustedKeys: {'test': await key.extractPublicKey()},
      device: const DeviceCapabilities(
        ramBytes: 6000000000,
        freeBytes: 4000000000,
        androidSdk: 29,
        arm64: true,
      ),
      appVersion: Version(0, 1, 0),
    );
    addTearDown(manager.dispose);
    await manager.install(
      PackManifest(map),
      DirectoryPackSource(source.parent),
    );
    final runtime = ModelRuntime(manager, manager.root);
    final speech = await runtime
        .speech(); // Native weights load lazily, not synthetic fixture inference.
    expect(speech.modelId, 'speech.test@1.0.0');
    await expectLater(runtime.speech(), throwsStateError);
    await speech.dispose();
    final next = await runtime.speech();
    await next.dispose();
    await File(
      '${manager.root.path}/speech.test/1.0.0/phonemes/data',
    ).writeAsString('tampered');
    expect(await runtime.installed(), isEmpty);
    await expectLater(runtime.speech(), throwsStateError);
  });
}
