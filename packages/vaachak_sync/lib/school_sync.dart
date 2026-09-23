import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/vaachak_store.dart';
import 'school_api.dart';
import 'vaachak_sync.dart';

class SchoolPairing {
  final String id, classId, learnerId, deviceId, name;
  final SecretKey secret;
  final Map<String, String> teacherKeys;
  final Map<String, dynamic> json;
  SchoolPairing(Map<String, dynamic> value)
    : json = Map.unmodifiable(value),
      id = value['id'] as String,
      classId = value['classId'] as String,
      learnerId = value['learnerId'] as String,
      deviceId = value['deviceId'] as String,
      name = value['name'] as String,
      teacherKeys = Map<String, String>.from(value['teacherKeys'] as Map),
      secret = SecretKey(_hex(value['secret'] as String));
  static List<int> _hex(String value) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw const FormatException('Invalid pairing key');
    }
    return [
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ];
  }

  BundleCodec get codec => BundleCodec(secret, id);
}

class SchoolTransport implements EventTransport {
  final SchoolApi api;
  final VaachakStore store;
  SchoolTransport(this.api, this.store);
  @override
  String get id => 'school:${api.scope}';
  @override
  Future<Set<String>> send(List<DomainEvent> events) async {
    final eligible = <DomainEvent>[];
    final localOnly = <String>{};
    for (final event in events) {
      if (event.deviceId == store.deviceId &&
          await store.metadata(
                'school:${api.scope}:joined:${event.learnerId}',
              ) ==
              'true') {
        eligible.add(event);
      } else {
        localOnly.add(event.id);
      }
    }
    if (eligible.isEmpty) return localOnly;
    final result = await api.rpc('ingest_events', {
      'batch': eligible.map((e) => e.toJson()).toList(),
    });
    final ids = (result['acceptedIds'] as List).cast<String>().toSet();
    if (!events.map((e) => e.id).toSet().containsAll(ids)) {
      throw const FormatException('Unexpected acknowledgement');
    }
    return {...ids, ...localOnly};
  }
}

/// Only authenticated RPC results, or signatures pinned during pairing, reach
/// this converter. Never accept unsigned offline teacher events.
DomainEvent interventionEvent(Map<String, dynamic> row) {
  final seq = row['delivery_seq'] as int;
  final millis = DateTime.parse(
    row['created_at'] as String,
  ).millisecondsSinceEpoch;
  final device = 'teacher_${row['teacher_id']}';
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  var number = BigInt.parse(
    sha256
        .convert(utf8.encode('intervention:${row['id']}'))
        .toString()
        .substring(0, 32),
    radix: 16,
  );
  var id = '';
  for (var i = 0; i < 26; i++) {
    id = alphabet[(number & BigInt.from(31)).toInt()] + id;
    number >>= 5;
  }
  if (!{
    'pin',
    'unpin',
    'assign',
    'approve',
    'reject',
    'replace',
  }.contains(row['kind'])) {
    throw const FormatException('Invalid intervention');
  }
  return DomainEvent(
    id: id,
    learnerId: row['learner_id'] as String,
    deviceId: device,
    seq: seq,
    hlc: HybridClock(millis, 0, device),
    type: 'TeacherIntervention',
    payload: {
      'nodeId': row['node_id'],
      'classId': row['class_id'],
      'teacherId': row['teacher_id'],
      'kind': row['kind'],
    },
  );
}

class SchoolSync {
  final VaachakStore store;
  final SkillGraph graph;
  final SchoolApi api;
  late final transport = SchoolTransport(api, store);
  bool _busy = false;
  SchoolSync(this.store, this.graph, this.api);
  String get _prefix => 'school:${api.scope}';
  Future<bool> permitted(String learner) async {
    if (await store.metadata('$_prefix:joined:$learner') != 'true') {
      return false;
    }
    final state = await store.snapshot(learner, graph);
    return state.consents['core'] == true &&
        state.consents['serverSync'] == true;
  }

  Future<void> register() =>
      api.rpc('register_device', {'device': store.deviceId});
  Future<Map<String, dynamic>> join(LocalProfile profile, String code) async {
    final state = await store.snapshot(profile.id, graph);
    if (state.consents['core'] != true ||
        state.consents['serverSync'] != true) {
      throw StateError('Sharing consent required');
    }
    await register();
    final result = Map<String, dynamic>.from(
      await api.rpc('join_class', {
        'code': code,
        'learner': profile.id,
        'display_name': profile.name,
        'age_band': profile.age.name,
        'is_minor': profile.minor,
        'sync_consent': true,
      }),
    );
    if (result['error'] != null) throw StateError(result['error'] as String);
    await store.setMetadata('$_prefix:joined:${profile.id}', 'true');
    return result;
  }

  Future<List<SchoolPairing>> pairings({bool refresh = true}) async {
    final key = '$_prefix:pairings';
    if (refresh) {
      final previous = (jsonDecode(await store.metadata(key) ?? '[]') as List)
          .cast<Map>();
      final fresh = (await api.rpc('sync_pairings') as List).cast<Map>();
      final ids = fresh.map((p) => p['id']).toSet();
      await store.transaction(() async {
        for (final old in previous) {
          if (!ids.contains(old['id'])) {
            await store.deleteMetadata('teacher.inbox:${old['id']}');
            await store.deleteMetadata('teacher.transfer:${old['id']}');
          }
        }
        await store.setMetadata(key, jsonEncode(fresh));
        await store.setMetadata(
          '$key:checked',
          DateTime.now().toUtc().toIso8601String(),
        );
      });
    } else {
      final checked = DateTime.tryParse(
        await store.metadata('$key:checked') ?? '',
      );
      if (checked == null ||
          DateTime.now().difference(checked) > const Duration(days: 7)) {
        return []; // Recheck assignment/key revocation at least weekly.
      }
    }
    return (jsonDecode(await store.metadata(key) ?? '[]') as List)
        .map((j) => SchoolPairing(Map<String, dynamic>.from(j as Map)))
        .toList();
  }

  Future<int> sync() async {
    if (_busy) return 0;
    _busy = true;
    try {
      await register();
      // Pull erasures first so revoked records cannot be reuploaded.
      await pull();
      final paired = await pairings();
      final allowed = paired.map((p) => p.learnerId).toSet();
      final agent = SyncAgent(
        store,
        transport,
        (id) async => allowed.contains(id) && await permitted(id),
      );
      final sent = await agent.flush();
      await pull();
      await store.setMetadata(
        '$_prefix:lastSync',
        DateTime.now().toUtc().toIso8601String(),
      );
      return sent;
    } finally {
      _busy = false;
    }
  }

  Future<void> pull() async {
    final cursorKey = '$_prefix:cursor';
    var cursor = int.tryParse(await store.metadata(cursorKey) ?? '') ?? 0;
    for (var page = 0; page < 20; page++) {
      final changes = await api.rpc('pull_changes', {'after_seq': cursor});
      for (final learner in (changes['erasures'] as List).cast<String>()) {
        await store.transaction(() async {
          if (!await store.isErased(learner)) await store.erase(learner);
          await store.setMetadata('$_prefix:joined:$learner', 'false');
          final previous = await pairings(refresh: false);
          await store.setMetadata(
            '$_prefix:pairings',
            jsonEncode(
              previous
                  .where((p) => p.learnerId != learner)
                  .map((p) => p.json)
                  .toList(),
            ),
          );
        });
        await api.rpc('ack_erasure', {'learner': learner});
      }
      final rows = (changes['interventions'] as List).cast<Map>();
      await store.transaction(() async {
        final profiles = (await store.profiles()).map((p) => p.id).toSet();
        for (final raw in rows) {
          final row = Map<String, dynamic>.from(raw);
          final event = interventionEvent(row);
          if (!graph.nodes.containsKey(event.payload['nodeId'])) {
            throw const FormatException('Unknown teacher skill');
          }
          if (profiles.contains(event.learnerId) &&
              !await store.isErased(event.learnerId)) {
            await store.importEvents(
              [event],
              allowedLearners: profiles,
              allowTeacherInterventions: true,
            );
            // Server-owned events must never enter the device upload queue.
            await store.acknowledge(transport.id, [event.id]);
          }
          if ((row['delivery_seq'] as int) > cursor) {
            cursor = row['delivery_seq'] as int;
          }
        }
        await store.setMetadata(cursorKey, '$cursor');
      });
      if (rows.length < 500) break;
    }
  }

  Future<Uint8List> exportProgress(SchoolPairing pair) async {
    if (pair.deviceId != store.deviceId) {
      throw StateError('Wrong paired device');
    }
    final shareProgress = await permitted(pair.learnerId);
    final pending =
        (await store.pending(transport.id, allowedLearners: {pair.learnerId}))
            .where(
              (e) =>
                  e.learnerId == pair.learnerId &&
                  e.deviceId == store.deviceId &&
                  (shareProgress ||
                      {'LearnerErased', 'ConsentRevoked'}.contains(e.type)),
            )
            .toList();
    // Export is not an acknowledgement; only the server can acknowledge delivery.
    return pair.codec.encode(ProgressBundle(store.deviceId, pending));
  }

  Future<int> relay(SchoolPairing pair, List<int> bytes) async {
    final bundle = await pair.codec.decode(bytes);
    if (bundle.deviceId != pair.deviceId ||
        bundle.events.any(
          (e) => e.learnerId != pair.learnerId || e.deviceId != pair.deviceId,
        )) {
      throw const FormatException('Transfer outside paired learner');
    }
    final result = await api.rpc('relay_events', {
      'pair_id': pair.id,
      'batch': bundle.events.map((e) => e.toJson()).toList(),
    });
    return (result['acceptedIds'] as List).length;
  }
}

/// Online-verified teacher public keys authenticate offline intervention files.
class TeacherTransfer {
  static Future<Uint8List> encode(
    SchoolPairing pair,
    String teacherId,
    SimpleKeyPair key,
    List<DomainEvent> events,
  ) async {
    if (events.any(
      (e) =>
          e.type != 'TeacherIntervention' ||
          e.learnerId != pair.learnerId ||
          e.payload['classId'] != pair.classId ||
          e.payload['teacherId'] != teacherId,
    )) {
      throw const FormatException('Invalid teacher transfer');
    }
    final encrypted = await pair.codec.encode(
      ProgressBundle('teacher_$teacherId', events),
    );
    final signature = await Ed25519().sign(encrypted, keyPair: key);
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'teacherId': teacherId,
          'body': base64Encode(encrypted),
          'signature': base64Encode(signature.bytes),
        }),
      ),
    );
  }

  static Future<int> receive(
    SchoolPairing pair,
    List<int> bytes,
    VaachakStore store,
    SkillGraph graph,
    String onlineTransport,
  ) async {
    if (bytes.length > BundleCodec.maxBytes * 2) {
      throw const FormatException('Oversized teacher file');
    }
    final envelope = jsonDecode(utf8.decode(bytes)) as Map;
    final teacher = envelope['teacherId'] as String;
    final public = pair.teacherKeys[teacher];
    if (envelope['v'] != 1 || public == null) {
      throw const FormatException('Teacher has not been paired');
    }
    final body = base64Decode(envelope['body'] as String);
    if (!await Ed25519().verify(
      body,
      signature: Signature(
        base64Decode(envelope['signature'] as String),
        publicKey: SimplePublicKey(
          base64Decode(public),
          type: KeyPairType.ed25519,
        ),
      ),
    )) {
      throw const FormatException('Invalid teacher signature');
    }
    final bundle = await pair.codec.decode(body);
    for (final event in bundle.events) {
      if (event.type != 'TeacherIntervention' ||
          event.learnerId != pair.learnerId ||
          event.payload['teacherId'] != teacher ||
          event.payload['classId'] != pair.classId ||
          !graph.nodes.containsKey(event.payload['nodeId'])) {
        throw const FormatException('Invalid intervention scope');
      }
    }
    return store.transaction(() async {
      final count = await store.importEvents(
        bundle.events,
        allowedLearners: {pair.learnerId},
        allowTeacherInterventions: true,
      );
      await store.acknowledge(onlineTransport, bundle.events.map((e) => e.id));
      return count;
    });
  }
}
