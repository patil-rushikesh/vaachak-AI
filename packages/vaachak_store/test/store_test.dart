import 'dart:io';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/vaachak_store.dart';
import 'package:vaachak_store/native.dart';

void main() {
  late VaachakStore store;
  setUp(
    () => store = VaachakStore(NativeDatabase.memory(), deviceId: 'device'),
  );
  tearDown(() => store.close());
  test('concurrent appends get unique sequences', () async {
    final e = await Future.wait(
      List.generate(25, (i) => store.append('learner', 'SessionStarted', {})),
    );
    expect(e.map((e) => e.seq).toSet().length, 25);
    expect((await store.events('learner')).length, 25);
  });
  test('PIN lockout persists', () async {
    final p = await store.createProfile(
      name: 'Riya',
      age: AgeBand.adult,
      minor: false,
      locale: 'en',
      pin: '123456',
      consentMethod: 'self',
    );
    final at = DateTime.utc(2026);
    for (var i = 0; i < 5; i++) {
      expect(await store.unlock(p.id, '000000', at: at), isFalse);
    }
    expect(() => store.unlock(p.id, '123456', at: at), throwsStateError);
    expect(
      await store.unlock(
        p.id,
        '123456',
        at: at.add(const Duration(minutes: 2)),
      ),
      isTrue,
    );
  });
  test('minor consent cannot be bypassed by age band', () async {
    expect(
      () => store.createProfile(
        name: 'R',
        age: AgeBand.student,
        minor: true,
        locale: 'en',
        pin: '123456',
        consentMethod: 'self',
      ),
      throwsStateError,
    );
  });
  test('idempotence and erasure prevent resurrection', () async {
    final other = VaachakStore(NativeDatabase.memory(), deviceId: 'other');
    addTearDown(other.close);
    final e = await other.append('learner', 'SessionStarted', {});
    expect(await store.importEvents([e], allowedLearners: {'learner'}), 1);
    expect(await store.importEvents([e], allowedLearners: {'learner'}), 0);
    await store.erase('learner');
    expect(await store.importEvents([e], allowedLearners: {'learner'}), 0);
    expect((await store.events('learner')).single.type, 'LearnerErased');
    expect(
      () => store.append('learner', 'SessionStarted', {}),
      throwsStateError,
    );
  });
  test('encryption rejects wrong key and hides plaintext', () async {
    final d = await Directory.systemTemp.createTemp('vaachak-test-');
    addTearDown(() => d.delete(recursive: true));
    final f = File('${d.path}/encrypted.db'), key = List.filled(64, 'a').join();
    var db = openEncryptedStore(f, key, 'device');
    await db.append('private-learner', 'SessionStarted', {});
    await db.close();
    expect(
      String.fromCharCodes(await f.readAsBytes()).contains('private-learner'),
      isFalse,
    );
    db = openEncryptedStore(f, List.filled(64, 'b').join(), 'device');
    await expectLater(db.events('private-learner'), throwsA(anything));
    await db.close();
    db = openEncryptedStore(f, key, 'device');
    expect((await db.events('private-learner')).length, 1);
    await db.close();
  });
  test(
    'consent-filtered pending queue cannot starve eligible learners',
    () async {
      await store.transaction(() async {
        for (var i = 0; i < 501; i++) {
          await store.append('private', 'SessionStarted', {});
        }
        await store.append('consented', 'SessionStarted', {});
      });
      final pending = await store.pending(
        'server',
        allowedLearners: {'consented'},
      );
      expect(pending.length, 1);
      expect(pending.single.learnerId, 'consented');
    },
  );
  test(
    'import rejects a batch atomically when a later event is outside the roster',
    () async {
      DomainEvent remote(int n, String learner) => DomainEvent(
        id: n.toString().padLeft(26, '0'),
        learnerId: learner,
        deviceId: 'remote',
        seq: n,
        hlc: HybridClock(1000 + n, 0, 'remote'),
        type: 'SessionStarted',
        payload: {},
      );
      await expectLater(
        store.importEvents(
          [remote(1, 'allowed'), remote(2, 'other')],
          allowedLearners: {'allowed'},
        ),
        throwsStateError,
      );
      expect(await store.events('allowed'), isEmpty);
    },
  );
  test(
    'SQLCipher 4 reopens and extends the previous SQLite3MC v4 fixture',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vaachak-legacy-',
      );
      final file = File('${directory.path}/legacy.db');
      await file.writeAsBytes(
        base64Decode(
          await File('test/fixtures/sqlite3mc-v4.db.b64').readAsString(),
        ),
      );
      final encrypted = openEncryptedStore(file, '1' * 64, 'legacy-device');
      try {
        final cipher = await encrypted
            .customSelect('PRAGMA cipher_version')
            .getSingle();
        expect(cipher.data.values.single.toString(), startsWith('4.'));
        final before = await encrypted.events('migration-fixture');
        expect(before.single.payload['fixture'], isTrue);
        await encrypted.append('migration-fixture', 'SessionEnded', {
          'durationMs': 1,
        });
        expect((await encrypted.events('migration-fixture')).length, 2);
      } finally {
        await encrypted.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
