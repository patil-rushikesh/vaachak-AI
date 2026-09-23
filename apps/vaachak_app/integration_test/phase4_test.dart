import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vaachak_app/privacy_controls.dart';
import 'package:vaachak_app/model_runtime.dart';
import 'package:vaachak_app/session.dart';
import 'package:vaachak_app/updates.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/native.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native consent withdrawal persists and Play failure preserves learning',
    (tester) async {
      final temp = await (await getTemporaryDirectory()).createTemp('phase4-');
      final file = File('${temp.path}/privacy.db');
      var store = openEncryptedStore(file, '7' * 64, 'phase4-device');
      final service = AppUpdateService();
      LearningSession? session;
      try {
        final profile = await store.createProfile(
          name: 'Synthetic privacy learner',
          age: AgeBand.student,
          minor: true,
          locale: 'en',
          pin: '246810',
          consentMethod: 'teacherWitnessedPaper',
          witnessReference: 'synthetic-core',
        );
        await expectLater(
          store.setConsent(profile.id, 'microphone', true),
          throwsStateError,
        );
        await store.setConsent(
          profile.id,
          'microphone',
          true,
          witnessReference: 'synthetic-mic',
        );
        final bank = ContentBank(
          SkillGraph([
            SkillNode(
              id: 'grammar',
              name: 'Grammar',
              skill: Skill.grammar,
              difficulty: 0,
              cefr: 'A1',
            ),
          ]),
          GrammarEngine([]),
          [],
        );
        session = LearningSession(store, bank, profile);
        await session.start();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: PrivacyControls(session: session)),
          ),
        );
        await tester.tap(find.text('Withdraw'));
        for (var n = 0; n < 150; n++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find
              .textContaining('Microphone consent withdrawn')
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        expect(
          find.textContaining('Microphone consent withdrawn'),
          findsOneWidget,
        );
        expect(session.snapshot.consents['microphone'], isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
        session = null;
        await store.close();
        store = openEncryptedStore(file, '7' * 64, 'phase4-device');
        expect(
          (await store.snapshot(profile.id, bank.graph)).consents['microphone'],
          isFalse,
        );
        expect(await store.unlock(profile.id, '246810'), isTrue);
        final version = await ModelRuntime.channel.invokeMethod<String>(
          'appVersion',
        );
        expect(version, isNotEmpty);
        await tester.pumpWidget(
          MaterialApp(home: UpdatePage(service: service)),
        );
        await tester.tap(find.text('Check and download update'));
        for (var n = 0; n < 250 && service.busy; n++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(service.busy, isFalse);
        // This test uses a sideloaded emulator build, so Google Play cannot update it.
        expect(service.message, contains('Updates are unavailable'));
        expect(await store.unlock(profile.id, '246810'), isTrue);
        await store.setConsent(profile.id, 'core', false);
        expect(await store.profiles(), isEmpty);
        expect(
          (await store.pending('school', allowedLearners: {})).single.type,
          'LearnerErased',
        );
        // ignore: avoid_print
        print(
          'PHASE4_NATIVE: guardian enforcement, privacy UI, encrypted reopen, erasure queue, app version and sideload update fallback passed',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        session?.dispose();
        service.dispose();
        await store.close();
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
