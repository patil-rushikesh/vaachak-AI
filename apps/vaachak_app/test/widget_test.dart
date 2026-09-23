import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaachak_app/main.dart';
import 'package:vaachak_app/teacher.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';

void main() {
  testWidgets('app displays a safe error if bundled content cannot validate', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contentProvider.overrideWith(
            (ref) => throw const FormatException('broken content'),
          ),
        ],
        child: const VaachakApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('content bank could not be validated'),
      findsOneWidget,
    );
  });
  testWidgets('unconfigured teacher portal shows no invented learner data', (
    tester,
  ) async {
    final bank = ContentBank(
      SkillGraph([
        SkillNode(
          id: 'v',
          name: 'Words',
          skill: Skill.vocabulary,
          difficulty: 0,
          cefr: 'A1',
        ),
      ]),
      GrammarEngine([]),
      [],
    );
    await tester.pumpWidget(MaterialApp(home: PlatformHome(bank: bank)));
    await tester.pumpAndSettle();
    expect(find.text('Connect your school'), findsOneWidget);
    expect(find.text('Teacher sign-in'), findsNothing);
  });
}
