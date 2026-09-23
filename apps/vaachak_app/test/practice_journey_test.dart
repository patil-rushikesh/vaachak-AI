import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaachak_app/learner.dart';
import 'package:vaachak_app/session.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_store/vaachak_store.dart';

void main() {
  late Directory dir;
  late VaachakStore store;
  late ContentBank bank;
  late LearningSession session;
  const id = '00000000000000000000000001';
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('journey-practice-');
    store = openEncryptedStore(File('${dir.path}/db'), 'b' * 64, 'test-device');
    bank = ContentBank.decode(
      File('assets/skill_graph.json').readAsStringSync(),
      File('assets/grammar_rules.json').readAsStringSync(),
      File('assets/items.json').readAsStringSync(),
    );
    session = LearningSession(
      store,
      bank,
      LocalProfile(id, 'Riya', AgeBand.child, 'en', false),
    );
    await store.append(id, 'ConsentGranted', {'purpose': 'core'});
    await session.start();
  });
  tearDown(() async {
    session.dispose();
    await store.close();
    await dir.delete(recursive: true);
  });
  testWidgets(
    'answer selection is reversible; check saves once; completion is earned',
    (tester) async {
      final item = bank.items.firstWhere((item) => item.approved);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PracticePage(
                      session: session,
                      items: [item],
                      title: 'Everyday words',
                    ),
                  ),
                ),
                child: const Text('Begin'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Begin'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(item.options[(item.answer + 1) % item.options.length]),
      );
      await tester.pump();
      expect(session.snapshot.evidenceIds, isEmpty);
      await tester.tap(find.text(item.options[item.answer]));
      await tester.pump();
      await tester.ensureVisible(find.text('Check answer'));
      await tester.tap(find.text('Check answer'));
      for (var i = 0; i < 100 && session.snapshot.evidenceIds.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(session.snapshot.evidenceIds.length, 1);
      expect(find.text('That’s right. Keep going!'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Back to your path'), 180);
      await tester.tap(find.text('Back to your path'));
      await tester.pumpAndSettle();
      expect(find.text('You showed up. You grew!'), findsOneWidget);
      expect(find.textContaining('1 of 1 correct.'), findsOneWidget);
      await tester.tap(find.text('Back to my trail'));
      await tester.pumpAndSettle();
      expect(find.text('Begin'), findsOneWidget);
    },
  );
}
