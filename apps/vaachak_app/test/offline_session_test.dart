import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaachak_app/offline_providers.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_store/vaachak_store.dart';

void main() {
  late Directory directory;
  late VaachakStore store;
  late LocalProfile profile;
  late ProviderContainer container;
  late ContentBank bank;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'vaachak-offline-provider-',
    );
    store = openEncryptedStore(
      File('${directory.path}/db'),
      'd' * 64,
      'device',
    );
    profile = await store.createProfile(
      name: 'Adult',
      age: AgeBand.adult,
      minor: false,
      locale: 'hi',
      pin: '123456',
      consentMethod: 'self',
    );
    bank = ContentBank(
      SkillGraph([
        SkillNode(
          id: 'g',
          name: 'Grammar',
          skill: Skill.grammar,
          difficulty: 0,
          cefr: 'A1',
        ),
      ]),
      GrammarEngine([]),
      [
        ContentItem.fromJson({
          'id': 'q',
          'version': 1,
          'nodeId': 'g',
          'type': 'choice',
          'difficulty': 0,
          'cefr': 'A1',
          'ageBands': ['adult'],
          'prompt': 'She … home.',
          'options': ['goes', 'go'],
          'answer': 0,
          'reviewStatus': 'approved',
          'reviewer': 'synthetic fixture only',
          'reviewedAt': '2026-09-23',
        }),
      ],
    );
    container = ProviderContainer();
  });
  tearDown(() async {
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    await store.close();
    await directory.delete(recursive: true);
  });
  OfflineSessionController controller() =>
      container.read(offlineSessionProvider.notifier);

  test('unlock validates PIN and progress changes notify Riverpod', () async {
    await expectLater(
      controller().unlock(store, bank, profile.id, '999999'),
      throwsA(isA<PinRejected>()),
    );
    expect(container.read(offlineSessionProvider).session, isNull);
    await controller().unlock(store, bank, profile.id, '123456');
    final session = container.read(offlineSessionProvider).session!;
    expect(session.profile.locale, 'hi');
    var changes = 0;
    final subscription = container.listen(
      offlineSessionProvider,
      (_, _) => changes++,
    );
    await session.answer(bank.items.single, 0, attemptId: 'step-1');
    expect(changes, 1);
    expect(session.snapshot.mastery['g']!.observations, 1);
    subscription.close();
    controller().lock();
    expect(container.read(offlineSessionProvider).session, isNull);
    await expectLater(session.answer(bank.items.single, 0), throwsStateError);
  });

  test('lock cancels an in-flight PIN check', () async {
    final opening = controller().unlock(store, bank, profile.id, '123456');
    controller().lock();
    await expectLater(opening, throwsA(isA<UnlockCancelled>()));
    expect(container.read(offlineSessionProvider).session, isNull);
    expect(
      (await store.events(profile.id)).where((e) => e.type == 'SessionStarted'),
      isEmpty,
    );
  });

  test(
    'profile switching isolates histories and closes the previous session',
    () async {
      final second = await store.createProfile(
        name: 'Second',
        age: AgeBand.adult,
        minor: false,
        locale: 'en',
        pin: '654321',
        consentMethod: 'self',
      );
      await controller().unlock(store, bank, profile.id, '123456');
      final previous = container.read(offlineSessionProvider).session!;
      await previous.answer(bank.items.single, 0);
      await controller().unlock(store, bank, second.id, '654321');
      final active = container.read(offlineSessionProvider).session!;
      expect(active.profile.id, second.id);
      expect(active.snapshot.mastery, isEmpty);
      expect(previous.ready, isFalse);
      await expectLater(
        previous.answer(bank.items.single, 1),
        throwsStateError,
      );
    },
  );

  test(
    'same practice command is idempotent and conflicting retries fail',
    () async {
      await controller().unlock(store, bank, profile.id, '123456');
      final session = container.read(offlineSessionProvider).session!;
      await Future.wait([
        session.answer(bank.items.single, 0, attemptId: 'same'),
        session.answer(bank.items.single, 0, attemptId: 'same'),
      ]);
      await session.answer(bank.items.single, 0, attemptId: 'same');
      expect(session.snapshot.mastery['g']!.observations, 1);
      await expectLater(
        session.answer(bank.items.single, 1, attemptId: 'same'),
        throwsStateError,
      );
      expect(
        (await store.events(
          profile.id,
        )).where((e) => e.type == 'PracticeAttempt').length,
        1,
      );
    },
  );

  test(
    'consent withdrawal blocks further work and refresh locks the provider',
    () async {
      await controller().unlock(store, bank, profile.id, '123456');
      final session = container.read(offlineSessionProvider).session!;
      await store.append(profile.id, 'ConsentRevoked', {'purpose': 'core'});
      await expectLater(session.answer(bank.items.single, 0), throwsStateError);
      await session.reloadProgress();
      expect(container.read(offlineSessionProvider).session, isNull);
    },
  );

  test(
    'failed practice insert can retry without a phantom mastery update',
    () async {
      await controller().unlock(store, bank, profile.id, '123456');
      final session = container.read(offlineSessionProvider).session!;
      await store.customStatement(
        "CREATE TRIGGER fail_practice BEFORE INSERT ON events WHEN NEW.type='PracticeAttempt' BEGIN SELECT RAISE(ABORT, 'disk full fixture'); END",
      );
      await expectLater(
        session.answer(bank.items.single, 0, attemptId: 'retry'),
        throwsA(isA<Exception>()),
      );
      expect(session.snapshot.mastery, isEmpty);
      await store.customStatement('DROP TRIGGER fail_practice');
      await session.answer(bank.items.single, 0, attemptId: 'retry');
      expect(session.snapshot.mastery['g']!.observations, 1);
    },
  );

  test('child consent cannot be bypassed through the store API', () async {
    await expectLater(
      store.createProfile(
        name: 'Child',
        age: AgeBand.child,
        minor: false,
        locale: 'en',
        pin: '123456',
        consentMethod: 'self',
      ),
      throwsArgumentError,
    );
    expect((await store.profiles()).length, 1);
  });
}
