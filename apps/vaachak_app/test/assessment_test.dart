import 'dart:io';
import 'package:flutter/material.dart';
import 'package:vaachak_app/assessment_page.dart';
import 'package:vaachak_app/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaachak_app/assessment_controller.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_store/vaachak_store.dart';

void main() {
  late Directory directory;
  late VaachakStore store;
  late ContentBank bank;
  late AssessmentController controller;
  const learner = 'learner';
  final profile = LocalProfile(learner, 'Test', AgeBand.adult, 'en', false);
  ContentBank fixture({
    bool approved = true,
    int? onlyDifficulty,
    String prompt = 'Choose',
  }) {
    final graph = SkillGraph([
      for (final skill in Skill.values)
        SkillNode(
          id: skill.name,
          name: skill.name,
          skill: skill,
          difficulty: 2,
          cefr: 'A1',
        ),
    ]);
    return ContentBank(graph, GrammarEngine([]), [
      for (final skill in Skill.values)
        for (var difficulty = 0; difficulty < 5; difficulty++)
          if (onlyDifficulty == null || difficulty == onlyDifficulty)
            for (var number = 0; number < 8; number++)
              ContentItem.fromJson({
                'id': '${skill.name}.$difficulty.$number',
                'version': 1,
                'type': 'choice',
                'nodeId': skill.name,
                'prompt': prompt,
                'cefr': 'A1',
                'difficulty': difficulty,
                'answer': 0,
                'options': ['Yes', 'No'],
                'ageBands': ['adult'],
                'reviewStatus': approved ? 'approved' : 'draft',
                'reviewer': 'test fixture only',
                'reviewedAt': '2026-09-23',
              }),
    ]);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vaachak-assessment-');
    store = openEncryptedStore(
      File('${directory.path}/db'),
      'b' * 64,
      'device',
    );
    bank = fixture();
    controller = AssessmentController(store, bank, profile);
    await store.append(learner, 'ConsentGranted', {'purpose': 'core'});
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test(
    'resume after encrypted database close without repeating an item',
    () async {
      final run = await controller.begin(Skill.grammar);
      final first = controller.next(run)!;
      expect(first.difficulty, 2);
      await controller.answer(run, first, 0);
      await store.close();
      store = openEncryptedStore(
        File('${directory.path}/db'),
        'b' * 64,
        'device',
      );
      controller = AssessmentController(store, bank, profile);
      final resumed = await controller.begin(Skill.grammar);
      expect(resumed.id, run.id);
      expect(resumed.answers.length, 1);
      expect(controller.next(resumed)!.difficulty, 3);
      expect(controller.next(resumed)!.id, isNot(first.id));
    },
  );

  test('duplicate and concurrent retries persist one answer', () async {
    final run = await controller.begin(Skill.grammar);
    final item = controller.next(run)!;
    await Future.wait([
      controller.answer(run, item, 0),
      controller.answer(run, item, 0),
    ]);
    await controller.answer(run, item, 0);
    expect((await controller.load())[Skill.grammar]!.answers.length, 1);
    expect(
      LearnerSnapshot.fold(
        bank.graph,
        learner,
        await store.events(learner),
      ).mastery['grammar']!.observations,
      1,
    );
    await expectLater(controller.answer(run, item, 1), throwsStateError);
  });

  test(
    'alternating staircase completes at six with atomic completion event',
    () async {
      var run = await controller.begin(Skill.sentence);
      for (var i = 0; i < 6; i++) {
        await controller.answer(run, controller.next(run)!, i % 2);
        run = (await controller.load())[Skill.sentence]!;
        expect(run.complete, i == 5);
      }
      expect(controller.next(run), isNull);
      final history = await store.events(learner);
      expect(history.where((e) => e.type == 'AssessmentCompleted').length, 1);
      expect(history.last.payload['count'], 6);
      expect((await controller.load()).keys, [Skill.sentence]);
    },
  );

  test(
    'eight correct answers complete without item repetition at boundary',
    () async {
      var run = await controller.begin(Skill.vocabulary);
      for (var i = 0; i < 8; i++) {
        await controller.answer(run, controller.next(run)!, 0);
        run = (await controller.load())[Skill.vocabulary]!;
      }
      expect(run.complete, isTrue);
      expect(run.usedItems.length, 8);
      expect(run.staircase.difficulty, 4);
    },
  );

  test(
    'completion write failure rolls back the final answer; retry succeeds',
    () async {
      var run = await controller.begin(Skill.grammar);
      for (var i = 0; i < 5; i++) {
        await controller.answer(run, controller.next(run)!, i % 2);
        run = (await controller.load())[Skill.grammar]!;
      }
      final item = controller.next(run)!;
      await store.customStatement(
        "CREATE TRIGGER fail_completion BEFORE INSERT ON events WHEN NEW.type='AssessmentCompleted' BEGIN SELECT RAISE(ABORT, 'disk failure fixture'); END",
      );
      await expectLater(
        controller.answer(run, item, 1),
        throwsA(isA<Exception>()),
      );
      expect((await controller.load())[Skill.grammar]!.answers.length, 5);
      await store.customStatement('DROP TRIGGER fail_completion');
      await controller.answer(run, item, 1);
      expect((await controller.load())[Skill.grammar]!.complete, isTrue);
    },
  );

  test(
    'missing rung pauses; no easier substitute or invented completion',
    () async {
      controller = AssessmentController(
        store,
        fixture(onlyDifficulty: 2),
        profile,
      );
      var run = await controller.begin(Skill.grammar);
      await controller.answer(run, controller.next(run)!, 0);
      run = (await controller.load())[Skill.grammar]!;
      expect(controller.next(run), isNull);
      expect(run.complete, isFalse);
      expect(
        controller.unavailable(Skill.grammar, run),
        contains('No unused reviewed question'),
      );
    },
  );

  test(
    'changed content is blocked even when item version was not bumped',
    () async {
      final run = await controller.begin(Skill.grammar);
      final changed = AssessmentController(
        store,
        fixture(prompt: 'Changed'),
        profile,
      );
      expect(changed.next(run), isNull);
      expect(changed.unavailable(Skill.grammar, run), contains('pack changed'));
      final replacement = await changed.begin(Skill.grammar, restart: true);
      expect(replacement.id, isNot(run.id));
      await expectLater(
        controller.answer(run, controller.next(run)!, 0),
        throwsStateError,
      );
    },
  );

  test(
    'drafts and choice-only speech or reading checks cannot start',
    () async {
      final draft = AssessmentController(
        store,
        fixture(approved: false),
        profile,
      );
      await expectLater(draft.begin(Skill.grammar), throwsStateError);
      for (final skill in [
        Skill.reading,
        Skill.listening,
        Skill.pronunciation,
        Skill.speaking,
      ]) {
        expect(controller.pool(skill), isEmpty);
        await expectLater(controller.begin(skill), throwsStateError);
      }
      expect(await controller.load(), isEmpty);
    },
  );

  test('consent is rechecked for each answer', () async {
    final run = await controller.begin(Skill.grammar);
    await store.append(learner, 'ConsentRevoked', {'purpose': 'core'});
    await expectLater(
      controller.answer(run, controller.next(run)!, 0),
      throwsStateError,
    );
    expect((await controller.load())[Skill.grammar]!.answers, isEmpty);
  });

  test(
    'foreign item cannot supply a score for the displayed question',
    () async {
      final run = await controller.begin(Skill.grammar);
      final wrong = controller.pool(Skill.vocabulary).first;
      await expectLater(controller.answer(run, wrong, 0), throwsStateError);
      expect((await controller.load())[Skill.grammar]!.answers, isEmpty);
    },
  );
  testWidgets(
    'assessment screen resumes saved question and shows unavailable skills',
    (tester) async {
      final session = LearningSession(store, bank, profile);
      addTearDown(session.dispose);
      await tester.runAsync(() async {
        final run = await controller.begin(Skill.grammar);
        await controller.answer(run, controller.next(run)!, 0);
        await session.start();
      });
      Future<void> settleDatabase() async {
        // Native SQLite uses an isolate. Let real I/O run, then drain widget
        // microtasks between replies instead of advancing only the fake clock.
        for (var attempt = 0; attempt < 200; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
            await tester.pumpAndSettle();
            return;
          }
        }
        fail('Assessment database operation did not settle');
      }

      await tester.pumpWidget(
        MaterialApp(home: AssessmentPage(session: session)),
      );
      await settleDatabase();
      expect(find.text('0 of 7 skill checks complete'), findsOneWidget);
      expect(find.text('1 answers saved · Resume'), findsOneWidget);
      await tester.tap(find.text('Grammar'));
      await tester.pumpAndSettle();
      expect(find.text('Question 2 of up to 8 · Level 4'), findsOneWidget);
      await tester.tap(find.text('Yes'));
      await settleDatabase();
      expect(find.text('Question 3 of up to 8 · Level 5'), findsOneWidget);
      await tester.tap(find.text('All skill checks'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Reading'));
      await tester.tap(find.text('Reading'));
      await tester.pumpAndSettle();
      expect(find.textContaining('It remains unassessed.'), findsOneWidget);
      expect(find.text('Yes'), findsNothing);
    },
  );
}
