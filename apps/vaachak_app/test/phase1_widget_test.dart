import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaachak_app/learner.dart';
import 'package:vaachak_app/main.dart' show VaachakApp, contentProvider;
import 'package:vaachak_app/learner_presentation.dart';
import 'package:vaachak_app/offline_providers.dart';
import 'package:vaachak_app/platform_native.dart';
import 'package:vaachak_app/session.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_store/vaachak_store.dart';

void main() {
  late Directory directory;
  late VaachakStore store;
  late ContentBank bank;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vaachak-ui-');
    store = openEncryptedStore(
      File('${directory.path}/db'),
      'e' * 64,
      'device',
    );
    bank = ContentBank(
      SkillGraph([
        for (final skill in Skill.values)
          SkillNode(
            id: skill.name,
            name: 'Fixture ${skill.name}',
            skill: skill,
            difficulty: 0,
            cefr: 'A1',
          ),
      ]),
      GrammarEngine([]),
      [
        ContentItem.fromJson({
          'id': 'q',
          'version': 1,
          'nodeId': 'grammar',
          'type': 'choice',
          'difficulty': 0,
          'cefr': 'A1',
          'ageBands': ['child', 'student', 'adult'],
          'prompt': 'She … home.',
          'options': ['goes', 'go'],
          'answer': 0,
          'reviewStatus': 'approved',
          'reviewer': 'test fixture',
          'reviewedAt': '2026-09-23',
        }),
      ],
    );
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  Future<void> awaitUi(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 240; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (done()) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('Offline UI did not settle');
  }

  Widget app(Widget child, String locale, {double scale = 1}) => MaterialApp(
    locale: Locale(locale),
    supportedLocales: const [Locale('en'), Locale('hi')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: child,
  );

  for (final age in AgeBand.values) {
    for (final locale in ['en', 'hi']) {
      testWidgets(
        '${age.name} dashboard in $locale fits narrow screen at 200% text',
        (tester) async {
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final session = LearningSession(
            store,
            bank,
            LocalProfile('learner', 'Riya', age, locale, age == AgeBand.child),
          );
          addTearDown(session.dispose);
          await tester.runAsync(() async {
            await store.append('learner', 'ConsentGranted', {
              'purpose': 'core',
            });
            await session.start();
            await session.answer(bank.items.single, 1);
            await session.answer(bank.items.single, 0);
          });
          await tester.pumpWidget(
            app(
              LearnerHome(
                session: session,
                onLock: () {},
                onErased: () async {},
              ),
              locale,
              scale: 2,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey('dashboard-${age.name}')), findsOneWidget);
          expect(
            find.text(locale == 'hi' ? 'नमस्ते, Riya।' : 'Hello, Riya.'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(locale == 'hi' ? 'प्रगति' : 'Progress'));
          await tester.pumpAndSettle();
          final progress = find.text(
            locale == 'hi'
                ? 'देखें आप कितना सीख रहे हैं'
                : 'Look how you’re growing',
          );
          expect(progress, findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(
            find.byTooltip(locale == 'hi' ? 'गोपनीयता' : 'Privacy'),
          );
          await tester.pumpAndSettle();
          expect(
            find.text(
              locale == 'hi'
                  ? 'आपका डेटा, आपका निर्णय'
                  : 'Your data, your choice',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'native profile picker unlocks offline, changes locale and locks from a child route',
    (tester) async {
      late LocalProfile profile;
      await tester.runAsync(() async {
        profile = await store.createProfile(
          name: 'Offline learner',
          age: AgeBand.adult,
          minor: false,
          locale: 'hi',
          pin: '123456',
          consentMethod: 'self',
        );
      });
      final container = ProviderContainer(
        overrides: [
          offlineStoreProvider.overrideWith((ref) async => store),
          contentProvider.overrideWith((ref) async => bank),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const VaachakApp(),
        ),
      );
      await awaitUi(
        tester,
        () => find.text(profile.name).evaluate().isNotEmpty,
      );
      await tester.tap(find.text(profile.name));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      await tester.runAsync(() async {
        await tester.tap(find.text('Continue'));
        for (
          var i = 0;
          i < 200 && container.read(offlineSessionProvider).session == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await awaitUi(
        tester,
        () =>
            find.byKey(const ValueKey('dashboard-adult')).evaluate().isNotEmpty,
      );
      expect(container.read(interfaceLocaleProvider), 'hi');
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        const Locale('hi'),
      );
      expect(find.text('नमस्ते, Offline learner।'), findsOneWidget);
      final practice = find.text('अभ्यास शुरू करें');
      await tester.scrollUntilVisible(practice, 250);
      await tester.tap(practice);
      await tester.pumpAndSettle();
      expect(find.text('She … home.'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(container.read(offlineSessionProvider).session, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('She … home.'), findsNothing);
      expect(find.text('आज कौन सीख रहा है?'), findsOneWidget);
    },
  );

  testWidgets(
    'Hindi profile creation refuses missing consent and localises age labels',
    (tester) async {
      await tester.pumpWidget(
        app(CreateProfile(store: store, hindi: true), 'hi', scale: 2),
      );
      await tester.scrollUntilVisible(
        find.text('प्रोफ़ाइल बनाएँ'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('प्रोफ़ाइल बनाएँ'));
      await tester.pumpAndSettle();
      expect(find.text('सहमति आवश्यक है।'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'age themes change reading size and touch targets, with high contrast',
    () {
      final base = ThemeData();
      final child = learnerTheme(base, AgeBand.child);
      final adult = learnerTheme(base, AgeBand.adult);
      expect(
        child.textTheme.bodyLarge!.fontSize,
        greaterThan(adult.textTheme.bodyLarge!.fontSize!),
      );
      expect(
        child.filledButtonTheme.style!.minimumSize!.resolve({})!.height,
        60,
      );
      expect(
        adult.filledButtonTheme.style!.minimumSize!.resolve({})!.height,
        48,
      );
      for (final age in AgeBand.values) {
        final theme = learnerTheme(base, age, highContrast: true);
        final a = theme.colorScheme.onSurface.computeLuminance();
        final b = theme.colorScheme.surfaceContainerLow.computeLuminance();
        final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(ratio, greaterThanOrEqualTo(7));
      }
    },
  );
}
