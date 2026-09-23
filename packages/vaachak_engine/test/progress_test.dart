import 'package:test/test.dart';
import 'package:vaachak_engine/vaachak_engine.dart';

void main() {
  final now = DateTime.utc(2026, 9, 23, 12);
  SkillNode node(String id, Skill skill) =>
      SkillNode(id: id, name: id, skill: skill, difficulty: 0, cefr: 'A1');
  final graph = SkillGraph([
    node('g1', Skill.grammar),
    node('g2', Skill.grammar),
    node('v1', Skill.vocabulary),
  ]);
  DomainEvent attempt(
    int seq,
    String node,
    double score,
    DateTime at, {
    String learner = 'learner',
  }) => DomainEvent(
    id: seq.toString().padLeft(26, '0'),
    learnerId: learner,
    deviceId: 'device',
    seq: seq,
    hlc: HybridClock(at.millisecondsSinceEpoch, 0, 'device'),
    type: 'PracticeAttempt',
    payload: {'nodeId': node, 'itemId': 'i$seq', 'score': score},
  );
  test('unassessed skills have no score or invented weaknesses', () {
    final result = LearnerProgress.from(graph, 'learner', [], now: now);
    expect(result.skills.length, 7);
    expect(
      result.skills.every((s) => s.mean == null && s.observations == 0),
      isTrue,
    );
    expect(result.weaknesses, isEmpty);
    expect(result.attemptsThisWeek, 0);
  });
  test(
    'evidence counts deduplicate and exclude other learners and future dates',
    () {
      final recent = attempt(2, 'g1', 0, now.subtract(const Duration(days: 1)));
      final result = LearnerProgress.from(
        graph,
        'learner',
        [
          attempt(1, 'g1', 1, now.subtract(const Duration(days: 8))),
          recent,
          recent,
          attempt(3, 'v1', 1, now),
          attempt(4, 'v1', 1, now.add(const Duration(days: 1))),
          attempt(5, 'g2', 0, now, learner: 'other'),
        ].reversed,
        now: now,
      );
      expect(result.attemptsThisWeek, 2);
      expect(result.activeDaysThisWeek, 2);
      expect(result.recent.length, 4);
      expect(
        result.skills
            .singleWhere((s) => s.skill == Skill.grammar)
            .observedNodes,
        1,
      );
      expect(result.weaknesses.map((n) => n.id), isNot(contains('g2')));
      expect(() => result.recent.clear(), throwsUnsupportedError);
    },
  );
  test('erasure removes all dashboard evidence', () {
    final erased = DomainEvent(
      id: '00000000000000000000000002',
      learnerId: 'learner',
      deviceId: 'device',
      seq: 2,
      hlc: HybridClock(now.millisecondsSinceEpoch, 0, 'device'),
      type: 'LearnerErased',
      payload: {},
    );
    final result = LearnerProgress.from(graph, 'learner', [
      attempt(1, 'g1', 0, now),
      erased,
    ], now: now);
    expect(result.weaknesses, isEmpty);
    expect(result.recent, isEmpty);
    expect(result.skills.every((s) => s.mean == null), isTrue);
  });
  test('availability is filtered before planner diversity limits', () {
    final many = SkillGraph([
      for (var i = 0; i < 5; i++) node('g$i', Skill.grammar),
    ]);
    final path = PathPlanner().plan(
      many,
      {},
      AgeBand.adult,
      now,
      eligibleNodeIds: {'g3', 'g4'},
    );
    expect(path.map((p) => p.node.id), ['g3', 'g4']);
    expect(path.every((p) => p.reason.isNotEmpty), isTrue);
  });
  test('activity days respect the supplied learner time-zone offset', () {
    final events = [
      attempt(1, 'g1', 1, DateTime.utc(2026, 9, 22, 20)),
      attempt(2, 'g1', 0, DateTime.utc(2026, 9, 23, 1)),
    ];
    expect(
      LearnerProgress.from(
        graph,
        'learner',
        events,
        now: now,
      ).activeDaysThisWeek,
      2,
    );
    expect(
      LearnerProgress.from(
        graph,
        'learner',
        events,
        now: now,
        dayOffset: const Duration(hours: 5, minutes: 30),
      ).activeDaysThisWeek,
      1,
    );
  });
}
