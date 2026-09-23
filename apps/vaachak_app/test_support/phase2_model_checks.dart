import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:vaachak_app/assessment_controller.dart';
import 'package:vaachak_app/model_runtime.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_packs/vaachak_packs.dart';
import 'package:vaachak_speech/vaachak_speech.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_store/vaachak_store.dart';

/// Real inference using an explicitly supplied, locally signed development pack.
/// The synthetic assessment below is test-only; it is never production content.
Future<void> checkPhase2Models(String sourcePath, {String? libraryPath}) async {
  final source = Directory(sourcePath);
  final publicKey = base64Decode(
    (await File(
      '${source.parent.path}/test-public-key.txt',
    ).readAsString()).trim(),
  );
  final manifest = PackManifest(
    jsonDecode(await File('$sourcePath/manifest.json').readAsString())
        as Map<String, dynamic>,
  );
  final DeviceCapabilities caps;
  if (Platform.isAndroid) {
    final native = (await ModelRuntime.channel.invokeMapMethod<String, dynamic>(
      'capabilities',
    ))!;
    caps = DeviceCapabilities(
      ramBytes: native['ramBytes'] as int,
      freeBytes: native['freeBytes'] as int,
      androidSdk: native['androidSdk'] as int,
      arm64: native['arm64'] as bool,
      thermalLimited: native['thermalLimited'] as bool,
    );
  } else {
    // Desktop tests validate native inference, not Android capability detection.
    caps = const DeviceCapabilities(
      ramBytes: 8000000000,
      freeBytes: 4000000000,
      androidSdk: 30,
      arm64: true,
    );
  }
  final tempRoot = Platform.isAndroid
      ? await getTemporaryDirectory()
      : Directory.systemTemp;
  final temp = await tempRoot.createTemp('vaachak-model-check-');
  final packs = PackManager(
    root: Directory('${temp.path}/packs'),
    trustedKeys: {
      'local-smoke-only': SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    },
    device: caps,
    appVersion: Version(0, 1, 0),
  );
  final store = openEncryptedStore(
    File('${temp.path}/evidence.db'),
    '7' * 64,
    'native-smoke-device',
  );
  final runtime = ModelRuntime(packs, packs.root);
  SpeechService? speech;
  AudioClip? audio;
  try {
    await packs.install(manifest, DirectoryPackSource(source));
    expect((await runtime.installed()).single.$1.id, manifest.id);
    speech = await runtime.speech(libraryPath: libraryPath);
    const reference = 'We read a book and learn new words every day.';
    audio = await speech.synthesise(reference);
    expect(audio.durationMs, inInclusiveRange(2000, 60000));
    expect(SignalQuality.measure(audio).scorable, isTrue);
    final transcript = await speech.recognise(audio);
    expect(transcript.words, isNotEmpty);
    expect(transcript.modelId, '${manifest.id}@${manifest.version}');
    final score = const ReadingAligner().score(
      reference,
      transcript.words,
      audio.durationMs,
    );
    expect(score.accuracy, greaterThanOrEqualTo(.7));
    expect(score.wcpm, greaterThan(0));
    if (Platform.isAndroid) {
      final bytes = ByteData(audio.samples.length * 2);
      for (var i = 0; i < audio.samples.length; i++) {
        bytes.setInt16(
          i * 2,
          (audio.samples[i] * 32767).round().clamp(-32768, 32767),
          Endian.little,
        );
      }
      try {
        await ModelRuntime.channel.invokeMethod<void>('playPcm', {
          'samples': bytes.buffer.asUint8List(),
          'sampleRate': audio.sampleRate,
        });
        await ModelRuntime.channel.invokeMethod<void>('stopPcm');
      } finally {
        bytes.buffer.asUint8List().fillRange(0, bytes.lengthInBytes, 0);
      }
    }
    final bank = ContentBank(
      SkillGraph([
        SkillNode(
          id: 'reading',
          name: 'Reading test',
          skill: Skill.reading,
          difficulty: 2,
          cefr: 'A1',
        ),
      ]),
      GrammarEngine([]),
      [],
      passages: [
        ReadingPassage.fromJson({
          'id': 'native.fixture',
          'version': 1,
          'nodeId': 'reading',
          'title': 'Synthetic integration fixture',
          'text': reference,
          'difficulty': 2,
          'cefr': 'A1',
          'ageBands': ['adult'],
          'targetWcpm': 60,
          'assessmentModelIds': [transcript.modelId],
          'reviewStatus': 'approved',
          'reviewer': 'synthetic test fixture only',
          'reviewedAt': '2026-09-23',
        }),
      ],
    );
    final profile = LocalProfile(
      'native-smoke',
      'Synthetic test',
      AgeBand.adult,
      'en',
      false,
    );
    await store.append(profile.id, 'ConsentGranted', {'purpose': 'core'});
    await store.append(profile.id, 'ConsentGranted', {'purpose': 'microphone'});
    final controller = AssessmentController(store, bank, profile);
    final run = await controller.begin(Skill.reading);
    final evidence = controller.evaluateReading(
      controller.nextReading(run)!,
      audio,
      transcript,
    );
    audio.clear();
    await controller.answerReading(run, evidence);
    await controller.answerReading(run, evidence);
    final events = await store.events(profile.id);
    final answers = events
        .where((e) => e.type == 'AssessmentItemAnswered')
        .toList();
    expect(answers, hasLength(1));
    expect(answers.single.payload.containsKey('audio'), isFalse);
    expect(answers.single.payload.containsKey('transcript'), isFalse);
    expect(answers.single.payload['modelId'], transcript.modelId);
    // Print measurements, not learner speech. These are smoke-test observations.
    // ignore: avoid_print
    print(
      'NATIVE_MODEL_CHECK: ${jsonEncode({'model': transcript.modelId, 'hasWordTiming': transcript.hasWordTiming, 'durationMs': audio.durationMs, 'accuracy': score.accuracy, 'wcpm': score.wcpm, 'persistedAnswers': answers.length, 'platform': Platform.operatingSystem})}',
    );
  } finally {
    audio?.clear();
    await speech?.dispose();
    await store.close();
    await packs.dispose();
    await temp.delete(recursive: true);
  }
}
