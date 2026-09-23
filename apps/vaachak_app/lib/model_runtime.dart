import 'dart:convert';
import 'package:vaachak_explain/vaachak_explain.dart';
import 'package:vaachak_explain/gemma.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:vaachak_packs/vaachak_packs.dart';
import 'package:vaachak_speech/sherpa.dart';

class ModelRuntime {
  static bool _leased = false;
  static void Function() _acquire() {
    if (_leased) throw StateError('Another offline model is in use');
    _leased = true;
    var released = false;
    return () {
      if (!released) {
        released = true;
        _leased = false;
      }
    };
  }

  static const channel = MethodChannel('ai.vaachak/device');
  final PackManager packs;
  final Directory directory;
  DeviceTier get tier => packs.device.tier;
  ModelRuntime(this.packs, this.directory);
  static Future<DeviceCapabilities> capabilities() async {
    final caps = await channel.invokeMapMethod<String, dynamic>('capabilities');
    if (caps == null) {
      throw StateError('Device capabilities are unavailable');
    }
    return DeviceCapabilities(
      ramBytes: caps['ramBytes'] as int,
      freeBytes: caps['freeBytes'] as int,
      androidSdk: caps['androidSdk'] as int,
      arm64: caps['arm64'] as bool,
      thermalLimited: caps['thermalLimited'] as bool,
    );
  }

  static Future<ModelRuntime> open() async {
    final device = await capabilities();
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}/packs',
    );
    await directory.create(recursive: true);
    const publicKey = String.fromEnvironment('PACK_PUBLIC_KEY'),
        keyId = String.fromEnvironment('PACK_KEY_ID');
    final keys = <String, SimplePublicKey>{};
    const keySet = String.fromEnvironment('PACK_PUBLIC_KEYS');
    if (keySet.isNotEmpty) {
      final entries = jsonDecode(keySet) as Map<String, dynamic>;
      if (entries.isEmpty || entries.length > 8) {
        throw StateError('Invalid release key set');
      }
      for (final entry in entries.entries) {
        final bytes = base64Decode(entry.value as String);
        if (entry.key.isEmpty || bytes.length != 32) {
          throw StateError('Invalid release key');
        }
        keys[entry.key] = SimplePublicKey(bytes, type: KeyPairType.ed25519);
      }
    }
    if (publicKey.isNotEmpty && keyId.isNotEmpty) {
      final bytes = base64Decode(publicKey);
      if (bytes.length != 32) {
        throw StateError('Invalid release public key');
      }
      keys[keyId] = SimplePublicKey(bytes, type: KeyPairType.ed25519);
    }
    if (keys.length > 8) throw StateError('Too many release keys');
    return ModelRuntime(
      PackManager(
        root: directory,
        trustedKeys: keys,
        device: device,
        refreshDevice: capabilities,
        appVersion: Version.parse(
          (await channel.invokeMethod<String>('appVersion'))!,
        ),
      ),
      directory,
    );
  }

  Future<List<(PackManifest, Directory)>> installed() async {
    final result = <(PackManifest, Directory)>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! Directory || entry.path.split('/').last.startsWith('.')) {
        continue;
      }
      final active = File('${entry.path}/active');
      if (!await active.exists()) {
        continue;
      }
      final version = (await active.readAsString()).trim();
      if (!RegExp(
        r'^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$',
      ).hasMatch(version)) {
        continue;
      }
      final folder = Directory('${entry.path}/$version'),
          manifestFile = File('${entry.path}/$version/manifest.json');
      if (!await manifestFile.exists() ||
          await manifestFile.length() > 1048576) {
        continue;
      }
      try {
        final manifest = PackManifest(
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
        );
        if (manifest.id != entry.path.split('/').last ||
            manifest.version != version) {
          continue;
        }
        await packs.verifyInstalled(manifest, folder);
        result.add((manifest, folder));
      } catch (_) {
        continue;
      }
    }
    result.sort((a, b) => a.$1.id.compareTo(b.$1.id));
    return result;
  }

  Future<ExplanationModel> explainer() async {
    if (tier != DeviceTier.a) {
      throw StateError('Explanation models require tier A');
    }
    for (final entry in await installed()) {
      final (manifest, folder) = entry;
      final runtime = manifest.json['runtime'];
      if (manifest.kind != 'explainer' ||
          runtime is! Map ||
          runtime['explainer'] is! Map) {
        continue;
      }
      final descriptor = runtime['explainer'] as Map;
      final release = _acquire();
      final model = GemmaExplanationModel(
        '${folder.path}/${descriptor['model']}',
      );
      try {
        await model.initialize();
        return _LeasedExplanation(model, release);
      } catch (_) {
        try {
          await model.close();
        } finally {
          release();
        }
        rethrow;
      }
    }
    throw StateError('Install a signed explanation pack first');
  }

  Future<SherpaSpeechService> speech({String? libraryPath}) async {
    for (final entry in await installed()) {
      final (manifest, folder) = entry;
      final runtime = manifest.json['runtime'];
      if (!{'core', 'speech'}.contains(manifest.kind) ||
          runtime is! Map ||
          runtime['asr'] is! Map ||
          runtime['tts'] is! Map) {
        continue;
      }
      String path(dynamic value) {
        if (value is! String ||
            !manifest.files.any((f) => f['path'] == value)) {
          throw StateError('Runtime references an unsigned model file');
        }
        return '${folder.path}/$value';
      }

      final asr = (runtime['asr'] as Map), tts = (runtime['tts'] as Map);
      final model = asr['type'] == 'whisper'
          ? sherpa.OfflineModelConfig(
              tokens: path(asr['tokens']),
              numThreads: 2,
              debug: false,
              whisper: sherpa.OfflineWhisperModelConfig(
                encoder: path(asr['encoder']),
                decoder: path(asr['decoder']),
                language: 'en',
                task: 'transcribe',
                enableTokenTimestamps: true,
                enableSegmentTimestamps: true,
              ),
            )
          : asr['type'] == 'zipformer'
          ? sherpa.OfflineModelConfig(
              tokens: path(asr['tokens']),
              numThreads: 2,
              debug: false,
              transducer: sherpa.OfflineTransducerModelConfig(
                encoder: path(asr['encoder']),
                decoder: path(asr['decoder']),
                joiner: path(asr['joiner']),
              ),
            )
          : throw StateError('Unsupported speech runtime');
      final dataDir = tts['dataDir'] as String;
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(dataDir) ||
          !manifest.files.any(
            (f) => (f['path'] as String).startsWith('$dataDir/'),
          )) {
        throw StateError('Unsigned TTS data directory');
      }
      return SherpaSpeechService(
        libraryPath: libraryPath,
        recognizerConfig: sherpa.OfflineRecognizerConfig(model: model),
        ttsConfig: sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            numThreads: 2,
            debug: false,
            vits: sherpa.OfflineTtsVitsModelConfig(
              model: path(tts['model']),
              tokens: path(tts['tokens']),
              dataDir: '${folder.path}/$dataDir',
            ),
          ),
        ),
        modelId: '${manifest.id}@${manifest.version}',
        onDispose: _acquire(),
      );
    }
    throw StateError(
      'Install a signed core speech pack to use the reading coach.',
    );
  }
}

class _LeasedExplanation implements ExplanationModel {
  final ExplanationModel delegate;
  final void Function() release;
  _LeasedExplanation(this.delegate, this.release);
  @override
  Future<String> generate(String prompt) => delegate.generate(prompt);
  @override
  Future<void> close() async {
    try {
      await delegate.close();
    } finally {
      release();
    }
  }
}
