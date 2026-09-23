import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaachak_app/learner.dart';
import 'package:vaachak_app/session.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_explain/vaachak_explain.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_store/vaachak_store.dart';

class TestSession extends LearningSession {
  TestSession(super.store, super.bank, super.profile) {
    ready = true;
  }
  @override
  Future<void> grammarViewed(GrammarCorrection correction) async {}
}

class PendingModel implements ExplanationModel {
  final output = Completer<String>();
  int calls = 0, closes = 0;
  @override
  Future<String> generate(String prompt) {
    calls++;
    return output.future;
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

void main() {
  final rule = GrammarRule(
    id: 'g',
    nodeId: 'g',
    pattern: r'\bShe go\b',
    replacement: 'She goes',
    explanation: 'Use goes with she.',
    practice: ['She goes home.', 'She goes to school.'],
    approved: true,
  );
  late Directory dir;
  late VaachakStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('grammar-ui');
    store = openEncryptedStore(File('${dir.path}/db'), 'f' * 64, 'test');
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  TestSession session(AgeBand age) => TestSession(
    store,
    ContentBank(
      SkillGraph([
        SkillNode(
          id: 'g',
          name: 'Grammar',
          skill: Skill.grammar,
          difficulty: 0,
          cefr: 'A1',
        ),
      ]),
      GrammarEngine([rule]),
      [],
    ),
    LocalProfile('p', 'Test', age, 'en', age == AgeBand.child),
  );
  for (final age in [AgeBand.child, AgeBand.adult]) {
    testWidgets('${age.name} gets template before any optional model', (
      tester,
    ) async {
      final model = PendingModel();
      final learner = session(age);
      await tester.pumpWidget(
        MaterialApp(
          home: GrammarPage(
            session: learner,
            explanationModelFactory: () => model,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'She go home.');
      await tester.tap(find.text('Check my sentence'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Use goes with she.'), findsOneWidget);
      expect(model.calls, 0);
      if (age == AgeBand.child) {
        expect(find.text('Try a local rewording'), findsNothing);
      } else {
        await tester.ensureVisible(find.text('Try a local rewording'));
        await tester.tap(find.text('Try a local rewording'));
        await tester.pump();
        expect(find.textContaining('Use goes with she.'), findsOneWidget);
        model.output.complete(
          jsonEncode({
            'explanation': 'Write She goes for one person.',
            'practice': rule.practice,
          }),
        );
        await tester.pumpAndSettle();
        expect(find.text('Write She goes for one person.'), findsOneWidget);
        expect(model.closes, 1);
      }
      await tester.pumpWidget(const SizedBox());
      learner.dispose();
    });
  }
}
