import 'package:test/test.dart';
import 'package:vaachak_engine/vaachak_engine.dart';

void main() {
  DomainEvent event(
    int sequence,
    String type,
    Map<String, dynamic> payload, {
    String device = 'device',
    String learner = 'learner',
  }) => DomainEvent(
    id: sequence.toString().padLeft(26, '0'),
    learnerId: learner,
    deviceId: device,
    seq: sequence,
    hlc: HybridClock(sequence, 0, device),
    type: type,
    payload: payload,
  );
  final start = event(1, 'AssessmentStarted', {
    'protocol': 1,
    'skill': 'grammar',
    'ageBand': 'adult',
    'initialDifficulty': 2,
    'bankDigest': 'a' * 64,
  });
  DomainEvent answer({
    String device = 'device',
    int ordinal = 0,
    int difficulty = 2,
  }) => event(2, 'AssessmentItemAnswered', {
    'assessmentId': start.id,
    'ordinal': ordinal,
    'skill': 'grammar',
    'itemId': 'item',
    'nodeId': 'grammar',
    'itemVersion': 1,
    'difficulty': difficulty,
    'score': .7,
  }, device: device);
  test('fold is order independent and deduplicates delivery', () {
    final a = answer();
    final run = SkillAssessment.fold('learner', [a, start, a])[Skill.grammar]!;
    expect(run.answers.length, 1);
    expect(run.staircase.difficulty, 3);
    expect(() => run.answers.clear(), throwsUnsupportedError);
  });
  test('rejects foreign device, missing steps and wrong difficulty', () {
    for (final a in [
      answer(device: 'other'),
      answer(ordinal: 1),
      answer(difficulty: 3),
    ]) {
      expect(
        () => SkillAssessment.fold('learner', [start, a]),
        throwsStateError,
      );
    }
  });
  test('completion marker cannot invent completion', () {
    expect(
      () => SkillAssessment.fold('learner', [
        start,
        event(3, 'AssessmentCompleted', {
          'assessmentId': start.id,
          'count': 8,
          'difficulty': 4,
        }),
      ]),
      throwsStateError,
    );
  });
  test(
    'erasure dominates assessment history and other learners are isolated',
    () {
      expect(SkillAssessment.fold('other', [start, answer()]), isEmpty);
      expect(
        SkillAssessment.fold('learner', [
          start,
          answer(),
          event(3, 'LearnerErased', {}),
        ]),
        isEmpty,
      );
    },
  );
}
