import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:vaachak_app/model_runtime.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_explain/vaachak_explain.dart';
import 'package:vaachak_packs/vaachak_packs.dart';

/// Opt-in test: requires user-authorized licensed weights already on Android.
/// The sidecar key is trusted only inside this test, never by the release app.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const sourcePath = String.fromEnvironment('PHASE2_EXPLAINER_PACK_DIR');
  testWidgets(
    'real signed Gemma inference and template-first validation on tier A',
    (tester) async {
      expect(
        Platform.isAndroid,
        isTrue,
        reason: 'Run this test on the target Android device or emulator.',
      );
      expect(
        sourcePath,
        isNotEmpty,
        reason:
            'Supply --dart-define=PHASE2_EXPLAINER_PACK_DIR=<device signed test pack path>',
      );
      final capabilities = await ModelRuntime.capabilities();
      expect(
        capabilities.tier,
        DeviceTier.a,
        reason:
            'Real device capability policy must allow the explainer; no capability overrides are used.',
      );
      final source = Directory(sourcePath);
      final key = base64Decode(
        (await File(
          '${source.parent.path}/test-public-key.txt',
        ).readAsString()).trim(),
      );
      expect(key.length, 32);
      final manifest = PackManifest(
        jsonDecode(await File('$sourcePath/manifest.json').readAsString())
            as Map<String, dynamic>,
      );
      expect(manifest.kind, 'explainer');
      final temp = await (await getTemporaryDirectory()).createTemp(
        'explainer-check-',
      );
      final packs = PackManager(
        root: Directory('${temp.path}/packs'),
        trustedKeys: {
          'local-smoke-only': SimplePublicKey(key, type: KeyPairType.ed25519),
        },
        device: capabilities,
        refreshDevice: ModelRuntime.capabilities,
        appVersion: Version(0, 1, 0),
      );
      ExplanationModel? model;
      ExplanationService? service;
      try {
        await packs.install(manifest, DirectoryPackSource(source));
        final runtime = ModelRuntime(packs, packs.root);
        expect((await runtime.installed()).single.$1.id, manifest.id);
        model = await runtime.explainer();
        final inference = Stopwatch()..start();
        final raw = await model
            .generate('Return exactly the words: Local inference works.')
            .timeout(const Duration(minutes: 2));
        inference.stop();
        expect(
          raw.trim(),
          isNotEmpty,
          reason: 'A safe fallback alone does not prove native inference ran.',
        );
        // Do not write generated content or learner data to test logs.
        // ignore: avoid_print
        print(
          jsonEncode({
            'check': 'real_explainer_inference',
            'durationMs': inference.elapsedMilliseconds,
            'generatedCharacters': raw.length,
          }),
        );

        final rule = GrammarRule(
          id: 'test-go',
          nodeId: 'test-grammar',
          pattern: r'\bShe go\b',
          replacement: 'She goes',
          explanation: 'Use goes with she.',
          practice: ['She goes home.', 'She goes to school.'],
          approved: true,
        );
        final grammar = GrammarEngine([rule]);
        final correction = grammar.check('She go home.')!;
        service = ExplanationService(grammar, model: model, enabled: true);
        final results = <Explanation>[];
        await for (final result in service.explain(correction, AgeBand.adult)) {
          results.add(result);
          if (results.length == 1) {
            expect(result.source, 'template');
            expect(result.text, correction.template(AgeBand.adult));
          }
        }
        expect(results.length, inInclusiveRange(1, 2));
        if (results.length == 2) {
          expect(results.last.source, 'model');
          expect(
            service.validate(
              jsonEncode({
                'explanation': results.last.text,
                'practice': results.last.practice,
              }),
              correction,
            ),
            isNotNull,
          );
        } else {
          expect(results.single.source, 'template');
        }
        // Schema/safety/latency rejection is reported distinctly from inference.
        // ignore: avoid_print
        print(
          jsonEncode({
            'check': 'real_explainer_validation',
            'nativeInferenceProducedText': true,
            'displayedSource': results.last.source,
            'validatedModelAccepted': results.length == 2,
            'templateFirst': results.first.source == 'template',
          }),
        );
      } finally {
        if (service != null) {
          await service.close();
        } else {
          await model?.close();
        }
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
