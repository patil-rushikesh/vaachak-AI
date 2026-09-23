import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/vaachak_store.dart';

void main() {
  late VaachakStore store;
  setUp(
    () => store = VaachakStore(NativeDatabase.memory(), deviceId: 'privacy'),
  );
  tearDown(() => store.close());
  Future<LocalProfile> profile({bool minor = true}) => store.createProfile(
    name: 'Synthetic',
    age: AgeBand.student,
    minor: minor,
    locale: 'en',
    pin: '246810',
    consentMethod: minor ? 'teacherWitnessedPaper' : 'self',
    witnessReference: minor ? 'core-paper-1' : null,
  );
  test('each minor purpose needs its own bounded guardian evidence', () async {
    final p = await profile();
    await expectLater(
      store.setConsent(p.id, 'microphone', true),
      throwsStateError,
    );
    await expectLater(
      store.setConsent(p.id, 'serverSync', true, witnessReference: 'x' * 121),
      throwsStateError,
    );
    await store.setConsent(
      p.id,
      'microphone',
      true,
      witnessReference: 'mic-paper-2',
    );
    final grants = (await store.events(
      p.id,
    )).where((e) => e.type == 'ConsentGranted');
    expect(grants.map((e) => e.payload['purpose']), ['core', 'microphone']);
    expect(grants.last.payload['verifiedVia'], 'teacherWitnessedPaper');
  });
  test(
    'withdrawal is independent and remains queued without sharing',
    () async {
      final p = await profile(minor: false);
      await store.setConsent(p.id, 'microphone', true);
      await store.setConsent(p.id, 'microphone', false);
      final pending = await store.pending('school', allowedLearners: {});
      expect(pending.single.type, 'ConsentRevoked');
      expect((await store.profiles()).single.id, p.id);
    },
  );
  test('core withdrawal purges profile and rejects reconsent', () async {
    final p = await profile();
    await store.setConsent(p.id, 'core', false);
    expect(await store.profiles(), isEmpty);
    expect((await store.events(p.id)).single.type, 'LearnerErased');
    await expectLater(
      store.setConsent(p.id, 'microphone', true, witnessReference: 'paper-3'),
      throwsStateError,
    );
    await expectLater(
      store.setConsent(p.id, 'telemetry', true),
      throwsArgumentError,
    );
  });
}
