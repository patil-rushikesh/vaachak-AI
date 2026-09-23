import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vaachak_app/teacher.dart' as teacher;
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_sync/school_api.dart';
import 'package:vaachak_sync/school_sync.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const raw = String.fromEnvironment('PHASE3_TEST_CONFIG');
  testWidgets(
    'teacher approves enrollment, sees evidence and pins practice through real backend',
    (tester) async {
      final config = jsonDecode(raw) as Map<String, dynamic>;
      final client = http.Client();
      SchoolApi api(String role) => SchoolApi(
        Uri.parse(config['url'] as String),
        'local-test',
        () async => config['${role}Token'] as String,
        client,
        allowLocalTest: true,
      );
      final teacherApi = api('teacher'), learnerApi = api('learner');
      final bank = ContentBank.decode(
        await rootBundle.loadString('assets/skill_graph.json'),
        await rootBundle.loadString('assets/grammar_rules.json'),
        await rootBundle.loadString('assets/items.json'),
      );
      final temp = await (await getTemporaryDirectory()).createTemp(
        'school-ui-',
      );
      final store = openEncryptedStore(
        File('${temp.path}/db'),
        '5' * 64,
        'phase3-device',
      );
      String? id;
      Future<void> until(bool Function() ready) async {
        for (var n = 0; n < 150; n++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (ready()) return;
        }
        throw StateError('UI did not reach expected state');
      }

      try {
        final profile = await store.createProfile(
          name: 'Synthetic teacher UI learner',
          age: AgeBand.adult,
          minor: false,
          locale: 'en',
          pin: '246810',
          consentMethod: 'self',
        );
        id = profile.id;
        await store.append(id, 'ConsentGranted', {
          'purpose': 'serverSync',
          'verifiedVia': 'self',
          'version': 1,
        });
        final sync = SchoolSync(store, bank.graph, learnerApi);
        final code = await teacherApi.rpc('create_join_code', {
          'target_class': config['classId'],
        });
        await sync.join(profile, code as String);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(home: teacher.PlatformHome(bank: bank)),
          ),
        );
        await until(
          () => find.byTooltip('Approve enrollment').evaluate().isNotEmpty,
        );
        await tester.ensureVisible(find.byTooltip('Approve enrollment'));
        await tester.tap(find.byTooltip('Approve enrollment'));
        await until(
          () => find.byTooltip('Approve enrollment').evaluate().isEmpty,
        );
        final node = bank.graph.nodes.keys.first;
        for (var n = 0; n < 6; n++) {
          await store.append(id, 'PracticeAttempt', {
            'nodeId': node,
            'itemId': 'ui-$n',
            'score': 0.0,
          });
        }
        await sync.sync();
        await tester.scrollUntilVisible(
          find.byTooltip('Refresh class'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byTooltip('Refresh class'));
        await until(() => find.text('6').evaluate().isNotEmpty);
        await tester.scrollUntilVisible(
          find.text(profile.name),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text(profile.name));
        await tester.pumpAndSettle();
        expect(
          find.text('0% · 6 attempts'),
          findsNothing,
        ); // BKT retains nonzero posterior.
        expect(
          find.textContaining(RegExp(r'^\d+% · 6 attempts$')),
          findsOneWidget,
        );
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pin practice'));
        await tester.pumpAndSettle();
        for (var n = 0; n < 50; n++) {
          await sync.pull();
          if ((await store.snapshot(id, bank.graph)).teacherWeights[node] ==
              3) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect((await store.snapshot(id, bank.graph)).teacherWeights[node], 3);
        // ignore: avoid_print
        print(
          'PHASE3_TEACHER_UI: enrollment approved, six attempts shown, pin received by learner',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (id != null) {
          try {
            await learnerApi.rpc('erase_learner', {'target_learner': id});
          } catch (_) {}
        }
        await store.close();
        client.close();
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
