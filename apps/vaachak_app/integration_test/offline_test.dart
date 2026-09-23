import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vaachak_app/main.dart';
import 'package:vaachak_app/offline_providers.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';

/// Reviewed fixtures belong only to this test; release assets remain unchanged.
ContentBank fixture() => ContentBank(
  SkillGraph([
    SkillNode(
      id: 'grammar',
      name: 'Grammar',
      skill: Skill.grammar,
      difficulty: 0,
      cefr: 'A1',
    ),
  ]),
  GrammarEngine([
    GrammarRule(
      id: 'go',
      nodeId: 'grammar',
      pattern: r'\bShe go\b',
      replacement: 'She goes',
      explanation: 'Use goes with she.',
      practice: ['She goes home.', 'She goes to school.'],
      approved: true,
    ),
  ]),
  [],
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'encrypted offline profile, grammar fallback and background lock',
    (tester) async {
      final container = ProviderContainer(
        overrides: [contentProvider.overrideWith((ref) async => fixture())],
      );
      final store = await container.read(offlineStoreProvider.future);
      final previousLocale = await store.metadata('interface.locale');
      await store.setMetadata('interface.locale', 'en');
      final name = 'Emulator ${DateTime.now().millisecondsSinceEpoch}';
      String? createdId;
      addTearDown(() async {
        container.read(offlineSessionProvider.notifier).lock();
        if (createdId != null) await store.erase(createdId);
        await store.setMetadata('interface.locale', previousLocale ?? 'en');
        container.dispose();
      });
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (done()) return;
        }
        fail('Offline state did not become ready');
      }

      Future<void> reveal(Finder finder) async {
        await tester.scrollUntilVisible(
          finder,
          240,
          maxScrolls: 50,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const VaachakApp(),
        ),
      );
      await until(
        () => find.text('Who is learning today?').evaluate().isNotEmpty,
      );
      await reveal(find.text('Create a learner profile'));
      await tester.tap(find.text('Create a learner profile'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, name);
      await tester.tap(find.text('Learner is under 18'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), '246810');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await reveal(find.text('Create profile'));
      await tester.tap(find.text('Create profile'));
      await tester.pumpAndSettle();
      expect(find.text('Consent is required.'), findsOneWidget);
      await reveal(
        find.text(
          'I consent to storing my progress for learning on this device.',
        ),
      );
      await tester.tap(
        find.text(
          'I consent to storing my progress for learning on this device.',
        ),
      );
      await tester.tap(find.text('Create profile'));
      await until(
        () => find.text('Who is learning today?').evaluate().isNotEmpty,
      );
      // The returning route is visible before its exit animation removes the
      // creation form. Its EditableText can still match the learner name.
      // Scope selection to the actual profile ListTile and settle the route.
      final profileTile = find.widgetWithText(ListTile, name);
      await until(() => profileTile.evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      createdId = (await store.profiles())
          .singleWhere((p) => p.name == name)
          .id;
      await reveal(profileTile);
      await tester.tap(profileTile);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '246810');
      await tester.tap(find.text('Continue'));
      await until(() => container.read(offlineSessionProvider).session != null);
      await tester.pumpAndSettle();
      await reveal(find.text('Explore a grammar correction'));
      await tester.tap(find.text('Explore a grammar correction'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'She go home.');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check my sentence'));
      await until(
        () => find.textContaining('Use goes with she.').evaluate().isNotEmpty,
      );
      await reveal(find.text('Try a local rewording'));
      await tester.tap(find.text('Try a local rewording'));
      await until(
        () => find
            .textContaining('The reviewed explanation is ready.')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.textContaining('Use goes with she.'), findsOneWidget);
      expect(
        (await store.events(createdId)).any((e) => e.type == 'CorrectionShown'),
        isTrue,
      );
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      expect(container.read(offlineSessionProvider).session, isNull);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(find.text('Who is learning today?'), findsOneWidget);
      expect(find.text('Check my sentence'), findsNothing);
    },
  );
}
