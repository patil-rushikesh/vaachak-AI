import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaachak_app/session.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_store/vaachak_store.dart';

void main() {
  late Directory directory;
  late VaachakStore store;
  late ContentBank bank;
  const learner = '00000000000000000000000001';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vaachak-session-');
    store = openEncryptedStore(
      File('${directory.path}/db'),
      'a' * 64,
      'device',
    );
    bank = ContentBank.decode(
      File('assets/skill_graph.json').readAsStringSync(),
      File('assets/grammar_rules.json').readAsStringSync(),
      File('assets/items.json').readAsStringSync(),
    );
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });
  LearningSession session(ContentBank content) => LearningSession(
    store,
    content,
    LocalProfile(learner, 'Test adult', AgeBand.adult, 'en', false),
  );
  test(
    'production recommendations exclude unavailable draft content',
    () async {
      await store.append(learner, 'ConsentGranted', {'purpose': 'core'});
      final draftOnly = ContentBank(
        bank.graph,
        bank.grammar,
        bank.items.where((item) => !item.approved).toList(),
      );
      final s = session(draftOnly);
      addTearDown(s.dispose);
      await s.start();
      expect(s.path, isEmpty);
    },
  );
  test('available reviewed practice persists before mastery changes', () async {
    final items =
        (jsonDecode(File('assets/items.json').readAsStringSync()) as List)
            .map(
              (j) => ContentItem.fromJson({
                ...j as Map<String, dynamic>,
                'reviewStatus': 'approved',
                'reviewer': 'test-fixture',
                'reviewedAt': '2026-09-23',
              }),
            )
            .toList();
    final content = ContentBank(bank.graph, bank.grammar, items);
    await store.append(learner, 'ConsentGranted', {'purpose': 'core'});
    final s = session(content);
    addTearDown(s.dispose);
    await s.start();
    expect(s.path, isNotEmpty);
    expect(s.path.every((r) => s.items(r.node.id).isNotEmpty), isTrue);
    final item = content.items.first;
    await s.answer(item, item.answer);
    expect(s.snapshot.mastery[item.nodeId]!.observations, 1);
    expect(
      (await store.events(
        learner,
      )).where((e) => e.type == 'PracticeAttempt').length,
      1,
    );
    await s.finish();
    expect((await store.events(learner)).last.type, 'SessionEnded');
  });
  test('revoked core consent blocks a new session', () async {
    await store.append(learner, 'ConsentGranted', {'purpose': 'core'});
    await store.append(learner, 'ConsentRevoked', {'purpose': 'core'});
    final s = session(bank);
    addTearDown(s.dispose);
    await expectLater(s.start(), throwsStateError);
    expect(
      (await store.events(learner)).any((e) => e.type == 'SessionStarted'),
      isFalse,
    );
  });
}
