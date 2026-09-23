import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_sync/school_api.dart';
import 'package:vaachak_sync/school_sync.dart';
import 'package:vaachak_sync/vaachak_sync.dart';

Future<void> checkPhase3(Map<String, dynamic> config) async {
  final client = http.Client();
  SchoolApi api(String role) => SchoolApi(
    Uri.parse(config['url'] as String),
    'local-test',
    () async => config['${role}Token'] as String,
    client,
    allowLocalTest: true,
  );
  final teacher = api('teacher'),
      learnerApi = api('learner'),
      outsider = api('outsider');
  final bank = ContentBank.decode(
    await rootBundle.loadString('assets/skill_graph.json'),
    await rootBundle.loadString('assets/grammar_rules.json'),
    await rootBundle.loadString('assets/items.json'),
  );
  final directory =
      await (Platform.isAndroid
              ? await getTemporaryDirectory()
              : Directory.systemTemp)
          .createTemp('phase3-check-');
  final store = openEncryptedStore(
    File('${directory.path}/learner.db'),
    '4' * 64,
    'phase3-device',
  );
  final sync = SchoolSync(store, bank.graph, learnerApi);
  String? learnerId;
  try {
    final profile = await store.createProfile(
      name: 'Synthetic Phase 3 learner',
      age: AgeBand.adult,
      minor: false,
      locale: 'en',
      pin: '246810',
      consentMethod: 'self',
    );
    learnerId = profile.id;
    await store.append(profile.id, 'ConsentGranted', {
      'purpose': 'serverSync',
      'verifiedVia': 'self',
      'version': 1,
    });
    final code = await teacher.rpc('create_join_code', {
      'target_class': config['classId'],
    });
    await expectLater(
      outsider.rpc('create_join_code', {'target_class': config['classId']}),
      throwsStateError,
    );
    expect((await sync.join(profile, code as String))['status'], 'pending');
    expect(await sync.pairings(), isEmpty);
    await expectLater(
      learnerApi.rpc('ingest_events', {
        'batch': (await store.events(
          profile.id,
        )).map((e) => e.toJson()).toList(),
      }),
      throwsStateError,
    );
    await teacher.rpc('review_enrollment', {
      'target_class': config['classId'],
      'target_learner': profile.id,
      'approve': true,
    });
    final teacherKey = await Ed25519().newKeyPair();
    await teacher.rpc('register_teacher_key', {
      'public_key': base64Encode((await teacherKey.extractPublicKey()).bytes),
    });
    final pair = (await sync.pairings()).single;
    final node = bank.graph.nodes.keys.first;
    for (var i = 0; i < 6; i++) {
      await store.append(profile.id, 'PracticeAttempt', {
        'itemId': 'synthetic-$i',
        'nodeId': node,
        'score': i == 5 ? 1.0 : 0.0,
      });
    }
    final encrypted = await sync.exportProgress(pair);
    expect(utf8.decode(encrypted).contains(profile.id), isFalse);
    // A lost file/QR transfer must not acknowledge unsent progress.
    expect(await store.pending(sync.transport.id), isNotEmpty);
    final qr = QrFountainEncoder(encrypted);
    final decoder = QrFountainDecoder();
    Uint8List? recovered;
    for (var i = qr.blocks - 1; i >= 0; i--) {
      recovered = decoder.add(qr.frame(i)) ?? recovered;
    }
    expect(recovered, encrypted);
    final teacherSync = SchoolSync(store, bank.graph, teacher);
    await teacherSync.relay(pair, recovered!);
    await teacherSync.relay(pair, recovered);
    final receiver = HotspotSharing(pair.codec, (bundle) async {
      await teacher.rpc('relay_events', {
        'pair_id': pair.id,
        'batch': bundle.events.map((e) => e.toJson()).toList(),
      });
    });
    final port = await receiver.start(InternetAddress.loopbackIPv4);
    try {
      await sendHotspot(Uri.parse('http://127.0.0.1:$port/vbundle'), encrypted);
    } finally {
      await receiver.stop();
    }
    await sync.sync();
    await sync.sync();
    await teacher.rpc('refresh_class_insights', {
      'target_class': config['classId'],
    });
    final insights = await teacher.request(
      'insights?learner_id=eq.${profile.id}',
    );
    expect((insights as List).single['evidence_ids'], hasLength(6));
    final states = await teacher.request(
      'learner_node_state?learner_id=eq.${profile.id}',
    );
    expect((states as List).single['n_obs'], 6);
    expect(
      await outsider.request('learner_node_state?learner_id=eq.${profile.id}'),
      isEmpty,
    );
    await expectLater(
      outsider.rpc('teacher_intervene', {
        'target_learner': profile.id,
        'target_class': config['classId'],
        'target_node': node,
        'action_kind': 'pin',
      }),
      throwsStateError,
    );
    await teacher.rpc('teacher_intervene', {
      'target_learner': profile.id,
      'target_class': config['classId'],
      'target_node': node,
      'action_kind': 'pin',
    });
    final changes = await learnerApi.rpc('pull_changes', {'after_seq': 0});
    final rows = (changes['interventions'] as List)
        .where((r) => r['learner_id'] == profile.id)
        .toList();
    final signed = await TeacherTransfer.encode(
      pair,
      config['teacherId'] as String,
      teacherKey,
      rows
          .map((r) => interventionEvent(Map<String, dynamic>.from(r as Map)))
          .toList(),
    );
    final corrupt = Uint8List.fromList(signed);
    corrupt[corrupt.length ~/ 2] ^= 1;
    await expectLater(
      TeacherTransfer.receive(
        pair,
        corrupt,
        store,
        bank.graph,
        sync.transport.id,
      ),
      throwsA(anything),
    );
    await TeacherTransfer.receive(
      pair,
      signed,
      store,
      bank.graph,
      sync.transport.id,
    );
    await sync.pull();
    await sync.pull();
    expect(
      (await store.snapshot(profile.id, bank.graph)).teacherWeights[node],
      3,
    );
    expect(
      (await store.events(
        profile.id,
      )).where((e) => e.type == 'TeacherIntervention').length,
      1,
    );
    // Server-confirmed revocation travels despite local sharing being off.
    await store.append(profile.id, 'ConsentRevoked', {'purpose': 'serverSync'});
    await sync.sync();
    expect(await sync.pairings(), isEmpty);
    await learnerApi.rpc('erase_learner', {'target_learner': profile.id});
    await sync.pull();
    expect(await store.isErased(profile.id), isTrue);
    expect(await store.profiles(), isEmpty);
    expect(
      await teacher.request('learner_node_state?learner_id=eq.${profile.id}'),
      isEmpty,
    );
    final tombstones = await learnerApi.request(
      'erasure_targets?learner_id=eq.${profile.id}',
    );
    expect((tombstones as List).single['acknowledged_at'], isNotNull);
    // ignore: avoid_print
    print(
      'PHASE3_CHECK: ${jsonEncode({'platform': Platform.operatingSystem, 'scoredAttempts': 6, 'duplicateSafe': true, 'crossClassDenied': true, 'qrAndLanRelay': true, 'signedInterventionApplied': true, 'erasureAcknowledged': true})}',
    );
  } finally {
    if (learnerId != null) {
      try {
        await learnerApi.rpc('erase_learner', {'target_learner': learnerId});
      } catch (_) {}
    }
    await store.close();
    client.close();
    await directory.delete(recursive: true);
  }
}
