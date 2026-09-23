import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaachak_engine/vaachak_engine.dart';

final interfaceLocaleProvider = NotifierProvider<InterfaceLocale, String>(
  InterfaceLocale.new,
);

class InterfaceLocale extends Notifier<String> {
  @override
  String build() => 'en';
  void select(String locale) {
    if (!{'en', 'hi'}.contains(locale)) {
      throw ArgumentError('Unsupported locale');
    }
    state = locale;
  }
}

class LearnerStrings {
  final String locale;
  const LearnerStrings(this.locale);
  String tr(String en, String hi) => locale == 'hi' ? hi : en;
  String skill(Skill skill) => locale == 'hi'
      ? const {
          Skill.vocabulary: 'शब्दावली',
          Skill.grammar: 'व्याकरण',
          Skill.sentence: 'वाक्य रचना',
          Skill.reading: 'पठन',
          Skill.pronunciation: 'उच्चारण',
          Skill.listening: 'सुनना',
          Skill.speaking: 'बोलना',
        }[skill]!
      : const {
          Skill.vocabulary: 'Vocabulary',
          Skill.grammar: 'Grammar',
          Skill.sentence: 'Sentence building',
          Skill.reading: 'Reading',
          Skill.pronunciation: 'Pronunciation',
          Skill.listening: 'Listening',
          Skill.speaking: 'Speaking',
        }[skill]!;
  String age(AgeBand age) => switch (age) {
    AgeBand.child => tr('Child', 'बच्चे'),
    AgeBand.student => tr('School / college', 'स्कूल / कॉलेज'),
    AgeBand.adult => tr('Adult', 'वयस्क'),
  };
  String band(Mastery? mastery) {
    if (mastery == null || mastery.observations == 0) {
      return tr('Not assessed', 'आकलन बाकी');
    }
    return switch (mastery.band) {
      'Strong' => tr('Strong', 'मज़बूत'),
      'Moderate' => tr('Building confidence', 'आत्मविश्वास बढ़ रहा है'),
      _ => tr('Ready to grow', 'और अभ्यास करें'),
    };
  }

  String evidence(int count) => tr(
    '$count saved attempts · ${count < 5 ? 'early evidence' : 'repeated evidence'}',
    '$count सुरक्षित प्रयास · ${count < 5 ? 'शुरुआती जानकारी' : 'कई प्रयासों की जानकारी'}',
  );
  String reason(
    Recommendation recommendation,
    SkillGraph graph,
    LearnerSnapshot state,
  ) {
    final node = recommendation.node;
    final mastery = state.mastery[node.id];
    final observation = mastery == null || mastery.observations == 0
        ? tr('Ready for a first check', 'पहले आकलन के लिए तैयार')
        : tr(
            'Estimated mastery ${(mastery.learned * 100).round()}% from ${mastery.observations} attempts',
            '${mastery.observations} प्रयासों से अनुमानित दक्षता ${(mastery.learned * 100).round()}%',
          );
    final dependencies = graph.blocks(node.id);
    final pin = (state.teacherWeights[node.id] ?? 1) >= 3;
    return '$observation${tr('; supports $dependencies next skills', '; आगे के $dependencies कौशलों में मदद')}${pin ? tr('; prioritised by your teacher', '; शिक्षक की प्राथमिकता') : ''}.';
  }
}

ThemeData learnerTheme(
  ThemeData base,
  AgeBand age, {
  bool highContrast = false,
}) {
  final seed = switch (age) {
    AgeBand.child => const Color(0xff205b47),
    AgeBand.student => const Color(0xff205b47),
    AgeBand.adult => const Color(0xff205b47),
  };
  final radius = switch (age) {
    AgeBand.child => 24.0,
    AgeBand.student => 16.0,
    AgeBand.adult => 10.0,
  };
  final height = age == AgeBand.child
      ? 60.0
      : age == AgeBand.student
      ? 52.0
      : 48.0;
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    contrastLevel: highContrast ? 1 : 0,
  );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xfff8f7f1),
    textTheme: base.typography.englishLike
        .merge(base.textTheme)
        .apply(fontSizeFactor: age == AgeBand.child ? 1.12 : 1),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: Size(48, height),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: Size(48, height),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, 48))),
    ),
  );
}
