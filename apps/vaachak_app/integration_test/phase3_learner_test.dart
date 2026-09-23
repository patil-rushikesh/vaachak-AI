import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vaachak_app/offline_providers.dart';
import 'package:vaachak_app/school_page.dart';
import 'package:vaachak_app/school_providers.dart';
import 'package:vaachak_app/session.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_sync/school_api.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const raw = String.fromEnvironment('PHASE3_TEST_CONFIG');
  testWidgets(
    'learner joins, shares approved progress, revokes sharing and erases through school UI',
    (tester) async {
      final config = jsonDecode(raw) as Map<String, dynamic>;
      final client = http.Client();
      final teacher = SchoolApi(
        Uri.parse(config['url'] as String),
        'local-test',
        () async => config['teacherToken'] as String,
        client,
        allowLocalTest: true,
      );
      final bank = ContentBank.decode(
        await rootBundle.loadString('assets/skill_graph.json'),
        await rootBundle.loadString('assets/grammar_rules.json'),
        await rootBundle.loadString('assets/items.json'),
      );
      final temp = await (await getTemporaryDirectory()).createTemp(
        'school-learner-ui-',
      );
      final store = openEncryptedStore(
        File('${temp.path}/db'),
        '6' * 64,
        'phase3-device',
      );
      final container = ProviderContainer(
        overrides: [offlineStoreProvider.overrideWith((_) async => store)],
      );
      LearningSession? session;
      String? id;
      Future<void> until(bool Function() predicate) async {
        for (var n = 0; n < 150; n++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (predicate()) return;
        }
        throw StateError(
          'School screen did not complete: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().join(' | ')}',
        );
      }

      Future<void> tap(String label) async {
        final f = find.text(label);
        await tester.scrollUntilVisible(
          f,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(f);
        await tester.pump();
      }

      try {
        final profile = await store.createProfile(
          name: 'Synthetic learner UI',
          age: AgeBand.adult,
          minor: false,
          locale: 'en',
          pin: '246810',
          consentMethod: 'self',
        );
        id = profile.id;
        session = LearningSession(store, bank, profile);
        await session.start();
        final code = await teacher.rpc('create_join_code', {
          'target_class': config['classId'],
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: SchoolPage(session: session)),
          ),
        );
        await until(
          () => find.text('Class joining code').evaluate().isNotEmpty,
        );
        await tester.enterText(find.byType(TextField), code as String);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        await tap('Request to join class');
        await until(
          () =>
              find.textContaining('Local class: pending').evaluate().isNotEmpty,
        );
        await teacher.rpc('review_enrollment', {
          'target_class': config['classId'],
          'target_learner': id,
          'approve': true,
        });
        final node = bank.graph.nodes.keys.first;
        await store.append(id, 'PracticeAttempt', {
          'nodeId': node,
          'itemId': 'synthetic-ui-item',
          'score': 1.0,
        });
        await tap('Sync now');
        await until(
          () =>
              find.textContaining('School sync complete').evaluate().isNotEmpty,
        );
        final states = await teacher.request(
          'learner_node_state?learner_id=eq.$id',
        );
        expect((states as List).single['n_obs'], 1);
        await tap('Stop sharing progress');
        await until(
          () => find
              .textContaining('Progress sharing stopped')
              .evaluate()
              .isNotEmpty,
        );
        expect(
          (await store.snapshot(id, bank.graph)).consents['serverSync'],
          isFalse,
        );
        final coordinator = (await container.read(
          schoolCoordinatorProvider(bank).future,
        ))!;
        expect(await coordinator.sync.pairings(), isEmpty);
        await store.erase(id);
        await coordinator.run();
        expect(await teacher.request('learners?id=eq.$id'), isEmpty);
        // ignore: avoid_print
        print(
          'PHASE3_LEARNER_UI: joined with consent, approved progress synced, sharing revoked, erasure delivered',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (id != null) {
          try {
            final coordinator = await container.read(
              schoolCoordinatorProvider(bank).future,
            );
            await coordinator?.connection.api.rpc('erase_learner', {
              'target_learner': id,
            });
          } catch (_) {}
        }
        session?.dispose();
        container.dispose();
        await store.close();
        client.close();
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
