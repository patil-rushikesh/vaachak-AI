import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaachak_app/assessment_controller.dart';
import 'package:vaachak_app/reading_page.dart';
import 'package:vaachak_app/session.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_speech/vaachak_speech.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_store/vaachak_store.dart';

void main() {
  const reference = 'we read a book and learn new words every day';
  const model = 'test.asr@1.0.0';
  final profile = LocalProfile('reader', 'Reader', AgeBand.adult, 'en', false);
  late Directory directory;
  late VaachakStore store;
  late ContentBank bank;
  late AssessmentController controller;
  Map<String, dynamic> passageJson(int difficulty, int index) => {
    'id': 'passage.$difficulty.$index',
    'version': 1,
    'nodeId': 'reading',
    'title': 'Reading fixture',
    'text': reference,
    'difficulty': difficulty,
    'cefr': 'A1',
    'ageBands': ['adult'],
    'targetWcpm': 60,
    'assessmentModelIds': [model],
    'reviewStatus': 'approved',
    'reviewer': 'synthetic test fixture only',
    'reviewedAt': '2026-09-23',
  };
  AudioClip clip({bool silence = false, int seconds = 5}) {
    final value = AudioClip(
      Float32List.fromList(
        List.generate(
          16000 * seconds,
          (i) => silence ? 0 : sin(i * .1) * (i < 4000 * seconds ? .001 : .2),
        ),
      ),
      16000,
    );
    addTearDown(value.clear);
    return value;
  }

  Transcript recognised({String text = reference, String modelId = model}) =>
      Transcript(
        normaliseWords(text).map((w) => SpokenWord(w, 0, 0)).toList(),
        modelId,
      );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vaachak-reading-');
    store = openEncryptedStore(
      File('${directory.path}/db'),
      'c' * 64,
      'device',
    );
    bank = ContentBank(
      SkillGraph([
        SkillNode(
          id: 'reading',
          name: 'Reading',
          skill: Skill.reading,
          difficulty: 2,
          cefr: 'A1',
        ),
      ]),
      GrammarEngine([]),
      [],
      passages: [
        for (var level = 0; level < 5; level++)
          for (var i = 0; i < 8; i++)
            ReadingPassage.fromJson(passageJson(level, i)),
      ],
    );
    controller = AssessmentController(store, bank, profile);
    await store.append(profile.id, 'ConsentGranted', {'purpose': 'core'});
    await store.append(profile.id, 'ConsentGranted', {'purpose': 'microphone'});
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test(
    'reading score combines word accuracy and reviewed pace target',
    () async {
      final run = await controller.begin(Skill.reading);
      final passage = controller.nextReading(run)!;
      final result = controller.evaluateReading(passage, clip(), recognised());
      expect(result.metrics['accuracy'], 1);
      expect(result.metrics['wcpm'], 120);
      expect(result.metrics['score'], 1);
      final partial = controller.evaluateReading(
        passage,
        clip(),
        recognised(text: 'we read a book and'),
      );
      expect(partial.metrics['score'], .5);
      final slower = controller.evaluateReading(
        passage,
        clip(seconds: 20),
        recognised(),
      );
      expect(slower.metrics['score'], .5);
    },
  );

  test(
    'numeric result retries once and resumes after encrypted reopen',
    () async {
      final run = await controller.begin(Skill.reading);
      final capture = clip();
      final result = controller.evaluateReading(
        controller.nextReading(run)!,
        capture,
        recognised(),
      );
      capture.clear();
      await Future.wait([
        controller.answerReading(run, result),
        controller.answerReading(run, result),
      ]);
      await store.close();
      store = openEncryptedStore(
        File('${directory.path}/db'),
        'c' * 64,
        'device',
      );
      controller = AssessmentController(store, bank, profile);
      final resumed = await controller.begin(Skill.reading);
      expect(resumed.answers.length, 1);
      expect(controller.nextReading(resumed)!.difficulty, 3);
      final payload = resumed.answers.single.payload;
      expect(payload.containsKey('transcript'), isFalse);
      expect(payload.containsKey('errors'), isFalse);
      expect(payload.containsKey('audio'), isFalse);
      expect(payload['modelId'], model);
      expect(
        () => (result.metrics['signalQuality'] as Map).clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'silence, short clips, empty speech and unapproved models remain unanswered',
    () async {
      final run = await controller.begin(Skill.reading);
      final passage = controller.nextReading(run)!;
      for (final input in [clip(silence: true), clip(seconds: 1)]) {
        expect(
          () => controller.evaluateReading(passage, input, recognised()),
          throwsStateError,
        );
      }
      expect(
        () => controller.evaluateReading(passage, clip(), recognised(text: '')),
        throwsStateError,
      );
      expect(
        () => controller.evaluateReading(
          passage,
          clip(),
          recognised(modelId: 'test.asr@2.0.0'),
        ),
        throwsStateError,
      );
      expect((await controller.load())[Skill.reading]!.answers, isEmpty);
    },
  );

  test(
    'revoked microphone consent blocks saving already evaluated evidence',
    () async {
      final run = await controller.begin(Skill.reading);
      final result = controller.evaluateReading(
        controller.nextReading(run)!,
        clip(),
        recognised(),
      );
      await store.append(profile.id, 'ConsentRevoked', {
        'purpose': 'microphone',
      });
      await expectLater(
        controller.answerReading(run, result),
        throwsStateError,
      );
      expect((await controller.load())[Skill.reading]!.answers, isEmpty);
    },
  );

  test('failed write retains numeric evidence for an idempotent retry', () async {
    final run = await controller.begin(Skill.reading);
    final result = controller.evaluateReading(
      controller.nextReading(run)!,
      clip(),
      recognised(),
    );
    await store.customStatement(
      "CREATE TRIGGER fail_reading BEFORE INSERT ON events WHEN NEW.type='AssessmentItemAnswered' BEGIN SELECT RAISE(ABORT, 'disk failure fixture'); END",
    );
    await expectLater(
      controller.answerReading(run, result),
      throwsA(isA<Exception>()),
    );
    expect((await controller.load())[Skill.reading]!.answers, isEmpty);
    await store.customStatement('DROP TRIGGER fail_reading');
    await controller.answerReading(run, result);
    await controller.answerReading(run, result);
    expect((await controller.load())[Skill.reading]!.answers.length, 1);
  });

  test('reading completion uses six alternating graded attempts', () async {
    var run = await controller.begin(Skill.reading);
    for (var i = 0; i < 6; i++) {
      final result = controller.evaluateReading(
        controller.nextReading(run)!,
        clip(),
        recognised(text: i.isEven ? reference : 'we read a book and'),
      );
      await controller.answerReading(run, result);
      run = (await controller.load())[Skill.reading]!;
    }
    expect(run.complete, isTrue);
    expect(run.usedItems.length, 6);
    expect((await store.events(profile.id)).last.type, 'AssessmentCompleted');
  });

  test(
    'changed reading rubric pauses resume without inventing a score',
    () async {
      final run = await controller.begin(Skill.reading);
      final changed = ContentBank(
        bank.graph,
        bank.grammar,
        [],
        passages: [
          ReadingPassage.fromJson({...passageJson(2, 0), 'targetWcpm': 80}),
        ],
      );
      final other = AssessmentController(store, changed, profile);
      expect(other.nextReading(run), isNull);
      expect(other.unavailable(Skill.reading, run), contains('pack changed'));
    },
  );

  testWidgets(
    'reading check hides coaching playback and can decline microphone',
    (tester) async {
      late SkillAssessment run;
      final session = LearningSession(store, bank, profile);
      addTearDown(session.dispose);
      await tester.runAsync(() async {
        run = await controller.begin(Skill.reading);
        await store.append(profile.id, 'ConsentRevoked', {
          'purpose': 'microphone',
        });
        await session.start();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ReadingPage(
            session: session,
            passage: controller.nextReading(run),
            assessment: run,
          ),
        ),
      );
      expect(find.text(reference), findsOneWidget);
      expect(find.text('Listen'), findsNothing);
      await tester.tap(find.text('Read aloud'));
      for (
        var i = 0;
        i < 100 && find.text('Use the microphone?').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      expect(find.text('Use the microphone?'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Read aloud'), findsOneWidget);
      await tester.runAsync(() async {
        expect((await controller.load())[Skill.reading]!.answers, isEmpty);
      });
    },
  );
}
