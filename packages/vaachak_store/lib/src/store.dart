import 'dart:convert';
import 'dart:math';
import 'package:drift/drift.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'pin.dart';

String newUlid([int? time]) {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final random = Random.secure();
  var value = BigInt.from(time ?? DateTime.now().millisecondsSinceEpoch) << 80;
  for (var i = 0; i < 10; i++) {
    value |= BigInt.from(random.nextInt(256)) << (i * 8);
  }
  var result = '';
  for (var i = 0; i < 26; i++) {
    result = alphabet[(value & BigInt.from(31)).toInt()] + result;
    value >>= 5;
  }
  return result;
}

class PinLocked extends StateError {
  PinLocked() : super('Too many attempts. Try again after the lockout ends.');
}

class LocalProfile {
  final String id, name, locale;
  final AgeBand age;
  final bool minor;
  LocalProfile(this.id, this.name, this.age, this.locale, this.minor);
}

class VaachakStore extends GeneratedDatabase {
  final String deviceId;
  VaachakStore(super.executor, {required this.deviceId});
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final statement in _schema) {
        await customStatement(statement);
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      final check = await customSelect('PRAGMA quick_check').get();
      if (check.length != 1 || check.first.data.values.first != 'ok') {
        throw StateError(
          'Database integrity check failed; do not overwrite this database',
        );
      }
    },
  );
  static const _schema = [
    'CREATE TABLE profiles (id TEXT PRIMARY KEY, name TEXT NOT NULL, age TEXT NOT NULL, locale TEXT NOT NULL, minor INTEGER NOT NULL, salt TEXT NOT NULL, pin_hash TEXT NOT NULL, failures INTEGER NOT NULL DEFAULT 0, locked_until INTEGER NOT NULL DEFAULT 0)',
    'CREATE TABLE device_clock (id TEXT PRIMARY KEY, seq INTEGER NOT NULL, hlc TEXT NOT NULL)',
    'CREATE TABLE events (id TEXT PRIMARY KEY, learner_id TEXT NOT NULL, device_id TEXT NOT NULL, seq INTEGER NOT NULL CHECK(seq > 0), hlc TEXT NOT NULL, type TEXT NOT NULL, v INTEGER NOT NULL CHECK(v=1), payload TEXT NOT NULL, UNIQUE(device_id, seq))',
    'CREATE INDEX events_learner_hlc ON events(learner_id, hlc, id)',
    'CREATE TRIGGER immutable_event BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT, \'Events are immutable\'); END',
    'CREATE TABLE acknowledgements (transport TEXT NOT NULL, event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE, PRIMARY KEY(transport,event_id))',
    'CREATE TABLE tombstones (learner_id TEXT PRIMARY KEY, event_json TEXT NOT NULL)',
    'CREATE TABLE snapshots (learner_id TEXT PRIMARY KEY, event_count INTEGER NOT NULL, last_hlc TEXT NOT NULL, body TEXT NOT NULL)',
    'CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  ];
  Future<List<LocalProfile>> profiles() async =>
      (await customSelect(
            'SELECT id,name,age,locale,minor FROM profiles ORDER BY name',
          ).get())
          .map(
            (r) => LocalProfile(
              r.read<String>('id'),
              r.read<String>('name'),
              AgeBand.values.byName(r.read<String>('age')),
              r.read<String>('locale'),
              r.read<int>('minor') == 1,
            ),
          )
          .toList();
  Future<LocalProfile> createProfile({
    required String name,
    required AgeBand age,
    required bool minor,
    required String locale,
    required String pin,
    required String consentMethod,
    String? witnessReference,
  }) async {
    if (name.trim().isEmpty ||
        name.length > 60 ||
        !{'en', 'hi'}.contains(locale)) {
      throw ArgumentError('Invalid profile');
    }
    if (age == AgeBand.child && !minor) {
      throw ArgumentError('Child profiles require guardian consent');
    }
    if (minor &&
        (consentMethod != 'teacherWitnessedPaper' ||
            witnessReference == null ||
            witnessReference.trim().length < 6 ||
            witnessReference.trim().length > 120)) {
      throw StateError(
        'A witnessed guardian consent reference is required for learners under 18',
      );
    }
    if (!minor && consentMethod != 'self') {
      throw ArgumentError('Adults must provide their own consent');
    }
    final id = newUlid(),
        salt = List.generate(16, (_) => Random.secure().nextInt(256));
    final hash = await PinHasher().hash(pin, salt);
    await transaction(() async {
      await customStatement(
        'INSERT INTO profiles(id,name,age,locale,minor,salt,pin_hash) VALUES(?,?,?,?,?,?,?)',
        [
          id,
          name.trim(),
          age.name,
          locale,
          minor ? 1 : 0,
          base64Encode(salt),
          hash,
        ],
      );
      await append(id, 'ProfileCreated', {
        'ageBand': age.name,
        'locale': locale,
        'minor': minor,
      });
      await append(id, 'ConsentGranted', {
        'purpose': 'core',
        'verifiedVia': consentMethod,
        'version': 1,
        if (minor) 'witnessReference': witnessReference,
      });
    });
    return LocalProfile(id, name.trim(), age, locale, minor);
  }

  /// Consent is purpose-specific. Withdrawing core consent erases the profile.
  Future<void> setConsent(
    String learner,
    String purpose,
    bool granted, {
    String? witnessReference,
  }) => transaction(() async {
    if (!{'core', 'microphone', 'serverSync'}.contains(purpose)) {
      throw ArgumentError('Unsupported consent purpose');
    }
    final profile = await customSelect(
      'SELECT minor FROM profiles WHERE id=?',
      variables: [Variable(learner)],
    ).getSingleOrNull();
    if (profile == null) throw StateError('Profile unavailable');
    if (!granted && purpose == 'core') {
      await erase(learner);
      return;
    }
    final minor = profile.read<int>('minor') == 1;
    final reference = witnessReference?.trim();
    if (granted &&
        minor &&
        (reference == null || reference.length < 6 || reference.length > 120)) {
      throw StateError('A witnessed guardian consent reference is required');
    }
    await append(learner, granted ? 'ConsentGranted' : 'ConsentRevoked', {
      'purpose': purpose,
      if (granted) 'version': 1,
      if (granted) 'verifiedVia': minor ? 'teacherWitnessedPaper' : 'self',
      if (granted && minor) 'witnessReference': reference,
    });
  });

  Future<bool> unlock(String id, String pin, {DateTime? at}) =>
      transaction(() async {
        final now = (at ?? DateTime.now()).millisecondsSinceEpoch;
        final row = await customSelect(
          'SELECT salt,pin_hash,failures,locked_until FROM profiles WHERE id=?',
          variables: [Variable(id)],
        ).getSingleOrNull();
        if (row == null) {
          return false;
        }
        if (row.read<int>('locked_until') > now) {
          throw PinLocked();
        }
        final valid = await PinHasher().verify(
          pin,
          base64Decode(row.read<String>('salt')),
          row.read<String>('pin_hash'),
        );
        final failures = valid ? 0 : row.read<int>('failures') + 1;
        final delay = failures < 5
            ? 0
            : min(3600000, 30000 * pow(2, min(7, failures - 5)).toInt());
        await customStatement(
          'UPDATE profiles SET failures=?,locked_until=? WHERE id=?',
          [failures, valid ? 0 : now + delay, id],
        );
        return valid;
      });
  Future<DomainEvent> append(
    String learner,
    String type,
    Map<String, dynamic> payload,
  ) => transaction(() async {
    if (await isErased(learner)) {
      throw StateError('Learner has been erased');
    }
    final row = await customSelect(
      'SELECT seq,hlc FROM device_clock WHERE id=?',
      variables: [Variable(deviceId)],
    ).getSingleOrNull();
    final now = DateTime.now().millisecondsSinceEpoch;
    final seq = (row?.read<int>('seq') ?? 0) + 1;
    final clock =
        (row == null
                ? HybridClock(0, 0, deviceId)
                : HybridClock.parse(row.read<String>('hlc')))
            .tick(now);
    final event = DomainEvent(
      id: newUlid(clock.millis),
      learnerId: learner,
      deviceId: deviceId,
      seq: seq,
      hlc: clock,
      type: type,
      payload: payload,
    );
    await _insert(event);
    await customStatement(
      'INSERT INTO device_clock(id,seq,hlc) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET seq=excluded.seq,hlc=excluded.hlc',
      [deviceId, seq, clock.toString()],
    );
    return event;
  });
  Future<void> _insert(DomainEvent e) async {
    await customStatement(
      'INSERT INTO events(id,learner_id,device_id,seq,hlc,type,v,payload) VALUES(?,?,?,?,?,?,?,?)',
      [
        e.id,
        e.learnerId,
        e.deviceId,
        e.seq,
        e.hlc.toString(),
        e.type,
        e.version,
        jsonEncode(e.payload),
      ],
    );
    await customStatement('DELETE FROM snapshots WHERE learner_id=?', [
      e.learnerId,
    ]);
  }

  DomainEvent _event(QueryRow r) => DomainEvent(
    id: r.read<String>('id'),
    learnerId: r.read<String>('learner_id'),
    deviceId: r.read<String>('device_id'),
    seq: r.read<int>('seq'),
    hlc: HybridClock.parse(r.read<String>('hlc')),
    type: r.read<String>('type'),
    version: r.read<int>('v'),
    payload: jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
  );
  Future<List<DomainEvent>> events(String learner) async => (await customSelect(
    'SELECT * FROM events WHERE learner_id=? ORDER BY hlc,id',
    variables: [Variable(learner)],
  ).get()).map(_event).toList();
  Future<bool> isErased(String learner) async =>
      await customSelect(
        'SELECT 1 FROM tombstones WHERE learner_id=?',
        variables: [Variable(learner)],
      ).getSingleOrNull() !=
      null;
  Future<LearnerSnapshot> snapshot(String learner, SkillGraph graph) async {
    final history = await events(learner),
        result = LearnerSnapshot.fold(graph, learner, history);
    if (!result.erased) {
      await customStatement(
        'INSERT INTO snapshots(learner_id,event_count,last_hlc,body) VALUES(?,?,?,?) ON CONFLICT(learner_id) DO UPDATE SET event_count=excluded.event_count,last_hlc=excluded.last_hlc,body=excluded.body',
        [
          learner,
          history.length,
          history.isEmpty ? '' : history.last.hlc.toString(),
          jsonEncode(result.mastery.map((k, v) => MapEntry(k, v.toJson()))),
        ],
      );
    }
    return result;
  }

  Future<int> importEvents(
    List<DomainEvent> incoming, {
    required Set<String> allowedLearners,
    bool allowTeacherInterventions = false,
  }) => transaction(() async {
    if (incoming.length > 500) {
      throw ArgumentError('Maximum 500 events per import');
    }
    var inserted = 0;
    for (final e in incoming) {
      if (!allowedLearners.contains(e.learnerId)) {
        throw StateError('Learner is outside the paired roster');
      }
      if (e.type == 'TeacherIntervention' && !allowTeacherInterventions) {
        throw StateError(
          'Teacher interventions require an authenticated teacher channel',
        );
      }
      if (e.deviceId == deviceId) {
        final local = await customSelect(
          'SELECT * FROM events WHERE id=?',
          variables: [Variable(e.id)],
        ).getSingleOrNull();
        if (local == null) {
          throw StateError(
            'Cannot import new events claiming this device identity',
          );
        }
      }
      if (await isErased(e.learnerId)) {
        continue;
      }
      final duplicate = await customSelect(
        'SELECT * FROM events WHERE id=? OR (device_id=? AND seq=?)',
        variables: [Variable(e.id), Variable(e.deviceId), Variable(e.seq)],
      ).get();
      if (duplicate.isNotEmpty) {
        if (duplicate.length != 1 ||
            canonicalEventJson(_event(duplicate.single).toJson()) !=
                canonicalEventJson(e.toJson())) {
          throw StateError('Conflicting event identity');
        }
        continue;
      }
      if (e.hlc.millis > DateTime.now().millisecondsSinceEpoch + 86400000) {
        throw FormatException('Remote clock is more than one day ahead');
      }
      await _insert(e);
      inserted++;
      if (e.type == 'LearnerErased') {
        await _purge(e);
      }
      final row = await customSelect(
        'SELECT seq,hlc FROM device_clock WHERE id=?',
        variables: [Variable(deviceId)],
      ).getSingleOrNull();
      final clock =
          (row == null
                  ? HybridClock(0, 0, deviceId)
                  : HybridClock.parse(row.read<String>('hlc')))
              .tick(DateTime.now().millisecondsSinceEpoch, e.hlc);
      await customStatement(
        'INSERT INTO device_clock(id,seq,hlc) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET hlc=excluded.hlc',
        [deviceId, row?.read<int>('seq') ?? 0, clock.toString()],
      );
    }
    return inserted;
  });
  Future<Set<String>> pendingLearners(
    String transport,
  ) async => (await customSelect(
    'SELECT DISTINCT learner_id FROM events e WHERE NOT EXISTS (SELECT 1 FROM acknowledgements a WHERE a.event_id=e.id AND a.transport=?)',
    variables: [Variable(transport)],
  ).get()).map((r) => r.read<String>('learner_id')).toSet();

  Future<List<DomainEvent>> pending(
    String transport, {
    int limit = 500,
    Set<String>? allowedLearners,
  }) async {
    if (limit < 1 || limit > 500) throw ArgumentError('Invalid batch size');
    final filter = allowedLearners == null
        ? ''
        : allowedLearners.isEmpty
        ? " AND e.type IN ('LearnerErased','ConsentRevoked')"
        : " AND (e.type IN ('LearnerErased','ConsentRevoked') OR e.learner_id IN (${List.filled(allowedLearners.length, '?').join(',')}))";
    return (await customSelect(
      'SELECT e.* FROM events e WHERE NOT EXISTS (SELECT 1 FROM acknowledgements a WHERE a.event_id=e.id AND a.transport=?)$filter ORDER BY e.hlc,e.id LIMIT ?',
      variables: [
        Variable(transport),
        if (allowedLearners != null) ...allowedLearners.map(Variable.new),
        Variable(limit),
      ],
    ).get()).map(_event).toList();
  }

  Future<void> acknowledge(
    String transport,
    Iterable<String> ids,
  ) => transaction(() async {
    for (final id in ids) {
      await customStatement(
        'INSERT OR IGNORE INTO acknowledgements(transport,event_id) VALUES(?,?)',
        [transport, id],
      );
    }
  });
  Future<void> erase(String learner) => transaction(() async {
    final e = await append(learner, 'LearnerErased', {
      'reason': 'consentRevoked',
    });
    await _purge(e);
  });
  Future<void> _purge(DomainEvent e) async {
    await customStatement(
      'INSERT OR IGNORE INTO tombstones(learner_id,event_json) VALUES(?,?)',
      [e.learnerId, jsonEncode(e.toJson())],
    );
    await customStatement('DELETE FROM events WHERE learner_id=? AND id<>?', [
      e.learnerId,
      e.id,
    ]);
    await customStatement('DELETE FROM profiles WHERE id=?', [e.learnerId]);
    await customStatement('DELETE FROM snapshots WHERE learner_id=?', [
      e.learnerId,
    ]);
  }

  Future<String> exportLearner(String learner) async => jsonEncode({
    'schemaVersion': 1,
    'learnerId': learner,
    'events': (await events(learner)).map((e) => e.toJson()).toList(),
  });
  Future<String?> metadata(String key) async => (await customSelect(
    'SELECT value FROM metadata WHERE key=?',
    variables: [Variable(key)],
  ).getSingleOrNull())?.read<String>('value');
  Future<void> deleteMetadata(String key) =>
      customStatement('DELETE FROM metadata WHERE key=?', [key]);
  Future<void> setMetadata(String key, String value) => customStatement(
    'INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
}
