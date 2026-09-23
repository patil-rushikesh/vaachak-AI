import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:vaachak_engine/vaachak_engine.dart';

List<dynamic> asset(String name) =>
    jsonDecode(
          File('../../apps/vaachak_app/assets/$name.json').readAsStringSync(),
        )
        as List;
void main() {
  final graph = SkillGraph(
    asset(
      'skill_graph',
    ).map((j) => SkillNode.fromJson(j as Map<String, dynamic>)),
  );
  final rules = asset('grammar_rules');
  final grammar = GrammarEngine(
    rules.map((j) => GrammarRule.fromJson(j as Map<String, dynamic>)),
  );
  test('70 acyclic nodes cover all seven skills', () {
    expect(graph.nodes.length, 70);
    expect(
      graph.nodes.values.map((n) => n.skill).toSet(),
      Skill.values.toSet(),
    );
  });
  test('missing and cyclic prerequisites fail closed', () {
    SkillNode node(String id, List<String> pre) => SkillNode(
      id: id,
      name: id,
      skill: Skill.grammar,
      difficulty: 0,
      cefr: 'A1',
      prerequisites: pre,
    );
    expect(
      () => SkillGraph([
        node('a', ['b']),
      ]),
      throwsArgumentError,
    );
    expect(
      () => SkillGraph([
        node('a', ['b']),
        node('b', ['a']),
      ]),
      throwsArgumentError,
    );
  });
  test('BKT golden binary and graded values', () {
    final p = BktParameters(), m = Mastery(), at = DateTime.utc(2026);
    expect(m.observe(1, p, at).learned, closeTo(.6926829268292684, 1e-12));
    expect(m.observe(0, p, at).learned, closeTo(.1457627118644068, 1e-12));
    expect(
      m.observe(.5, p, at).learned,
      closeTo((.6926829268292684 + .1457627118644068) / 2, 1e-12),
    );
  });
  test('BKT invariants and invalid evidence', () {
    final random = Random(42);
    var m = Mastery();
    for (var i = 0; i < 10000; i++) {
      m = m.observe(random.nextDouble(), BktParameters(), DateTime.utc(2026));
      expect(m.learned, inInclusiveRange(0, 1));
    }
    expect(
      () => m.observe(double.nan, BktParameters(), DateTime.now()),
      throwsArgumentError,
    );
    expect(
      () => m.observe(1.01, BktParameters(), DateTime.now()),
      throwsArgumentError,
    );
  });
  test('planner gates prerequisites and limits skills', () {
    final path = PathPlanner().plan(
      graph,
      {},
      AgeBand.child,
      DateTime.utc(2026),
    );
    expect(path.length, 5);
    expect(path.every((p) => p.node.prerequisites.isEmpty), isTrue);
    for (final s in Skill.values) {
      expect(path.where((p) => p.node.skill == s).length, lessThanOrEqualTo(2));
    }
    expect(
      PathPlanner()
          .plan(
            graph,
            {},
            AgeBand.child,
            DateTime.utc(2026),
            teacherWeights: {'vocabulary.frequent_500': 0},
          )
          .any((p) => p.node.id == 'vocabulary.frequent_500'),
      isFalse,
    );
  });
  test('difficulty and assessment stop rules', () {
    var ladder = const DifficultyLadder();
    for (var i = 0; i < 3; i++) {
      ladder = ladder.observe(.8);
    }
    expect(ladder.rung, 3);
    ladder = ladder.observe(.2).observe(.2);
    expect(ladder.rung, 2);
    expect(ladder.workedExample, isTrue);
    var a = AssessmentStaircase();
    for (final s in [1.0, 0.0, 1.0, 0.0, 1.0, 0.0]) {
      a = a.observe(s);
    }
    expect(a.complete, isTrue);
  });
  test('HLC survives rollback and remote clocks', () {
    final first = HybridClock(1000, 0, 'device');
    var clock = first.tick(1);
    expect(clock.compareTo(first), greaterThan(0));
    clock = clock.tick(2, HybridClock(2000, 3, 'remote'));
    expect(clock.millis, 2000);
    expect(clock.counter, 4);
    expect(HybridClock.parse(clock.toString()).toString(), clock.toString());
  });
  for (final j in rules) {
    test('grammar ${j['id']} positive and negative fixture', () {
      final result = grammar.check(j['bad'] as String);
      expect(result, isNotNull);
      expect(result!.corrected, j['good']);
      expect(grammar.check(j['good'] as String), isNull);
    });
  }
  test('contractions and numbers normalise', () {
    expect(normaliseWords("I can't see 2 birds."), [
      'i',
      'can',
      'not',
      'see',
      'two',
      'birds',
    ]);
  });
  test('WCPM and reading error classes', () {
    const a = ReadingAligner();
    final exact = a.score('We read books', [
      const SpokenWord('We', 0, 300),
      const SpokenWord('read', 300, 600),
      const SpokenWord('books', 600, 900),
    ], 3000);
    expect(exact.wcpm, 60);
    expect(exact.accuracy, 1);
    expect(exact.errors, isEmpty);
    expect(
      a
          .score('We read books', [
            const SpokenWord('We', 0, 300),
            const SpokenWord('books', 300, 600),
          ], 3000)
          .errors
          .any((e) => e.kind == ReadingErrorKind.omission),
      isTrue,
    );
    final repeated = a.score('We read', [
      const SpokenWord('We', 0, 100),
      const SpokenWord('We', 100, 200),
      const SpokenWord('read', 1200, 1500),
    ], 3000);
    expect(
      repeated.errors.any((e) => e.kind == ReadingErrorKind.repetition),
      isTrue,
    );
    expect(
      repeated.errors.any((e) => e.kind == ReadingErrorKind.hesitation),
      isTrue,
    );
  });
  DomainEvent event(int n, double score) => DomainEvent(
    id: n.toString().padLeft(26, '0'),
    learnerId: 'learner',
    deviceId: 'device',
    seq: n,
    hlc: HybridClock(1000 + n, 0, 'device'),
    type: 'PracticeAttempt',
    payload: {
      'nodeId': 'vocabulary.frequent_500',
      'itemId': 'item',
      'score': score,
    },
  );
  test('duplicate and shuffled events converge', () {
    final h = [event(1, 1), event(2, 0), event(3, .7)],
        expected = LearnerSnapshot.fold(graph, 'learner', [
          event(1, 1),
          event(2, 0),
          event(3, .7),
        ]);
    for (var seed = 0; seed < 100; seed++) {
      final shuffled = [...h, ...h]..shuffle(Random(seed));
      final a = LearnerSnapshot.fold(graph, 'learner', shuffled);
      expect(
        a.mastery['vocabulary.frequent_500']!.learned,
        expected.mastery['vocabulary.frequent_500']!.learned,
      );
      expect(a.evidenceIds.length, 3);
    }
  });
  test('erasure dominates all observations', () {
    final e = DomainEvent(
      id: '00000000000000000000000009',
      learnerId: 'learner',
      deviceId: 'device',
      seq: 9,
      hlc: HybridClock(1009, 0, 'device'),
      type: 'LearnerErased',
      payload: {},
    );
    final s = LearnerSnapshot.fold(graph, 'learner', [
      event(10, 1),
      e,
      event(1, 1),
    ]);
    expect(s.erased, isTrue);
    expect(s.mastery, isEmpty);
  });
  test('raw audio and unknown schema keys rejected', () {
    expect(
      () => DomainEvent.fromJson({...event(1, 1).toJson(), 'audio': 'secret'}),
      throwsFormatException,
    );
    expect(
      () => DomainEvent(
        id: '00000000000000000000000001',
        learnerId: 'a',
        deviceId: 'd',
        seq: 1,
        hlc: HybridClock(1, 0, 'd'),
        type: 'SessionEnded',
        payload: {
          'nested': {
            'audio': [1, 2],
          },
        },
      ),
      throwsFormatException,
    );
  });
  test(
    'event payloads are deeply immutable and duplicate key order is irrelevant',
    () {
      final first = DomainEvent(
        id: '00000000000000000000000007',
        learnerId: 'learner',
        deviceId: 'device',
        seq: 7,
        hlc: HybridClock(1007, 0, 'device'),
        type: 'SessionStarted',
        payload: {
          'a': {
            'nested': [1, 2],
          },
          'b': 3,
        },
      );
      expect(
        () => (first.payload['a'] as Map)['nested'] = [],
        throwsUnsupportedError,
      );
      final second = DomainEvent.fromJson({
        ...first.toJson(),
        'payload': {
          'b': 3,
          'a': {
            'nested': [1, 2],
          },
        },
      });
      expect(
        () => LearnerSnapshot.fold(graph, 'learner', [first, second]),
        returnsNormally,
      );
    },
  );
  test('one teacher cannot cancel another class teacher pin', () {
    DomainEvent intervention(int n, String teacher, String kind) => DomainEvent(
      id: n.toString().padLeft(26, '0'),
      learnerId: 'learner',
      deviceId: 'device',
      seq: n,
      hlc: HybridClock(1000 + n, 0, 'device'),
      type: 'TeacherIntervention',
      payload: {
        'nodeId': 'grammar.articles',
        'classId': teacher,
        'teacherId': teacher,
        'kind': kind,
      },
    );
    final snapshot = LearnerSnapshot.fold(graph, 'learner', [
      intervention(1, 'teacher-a', 'pin'),
      intervention(2, 'teacher-b', 'pin'),
      intervention(3, 'teacher-b', 'unpin'),
    ]);
    expect(snapshot.teacherWeights['grammar.articles'], 3);
  });
  test('replacement clears only the same teacher and class pins', () {
    DomainEvent event(int n, String teacher, String node, String kind) =>
        DomainEvent(
          id: n.toString().padLeft(26, '0'),
          learnerId: 'learner',
          deviceId: 'device',
          seq: n,
          hlc: HybridClock(1000 + n, 0, 'device'),
          type: 'TeacherIntervention',
          payload: {
            'nodeId': node,
            'classId': 'class',
            'teacherId': teacher,
            'kind': kind,
          },
        );
    final first = 'grammar.articles';
    final next = graph.nodes.keys.firstWhere((id) => id != first);
    final replaced = LearnerSnapshot.fold(graph, 'learner', [
      event(1, 'a', first, 'pin'),
      event(2, 'a', next, 'replace'),
    ]);
    expect(replaced.teacherWeights[first], 0);
    expect(replaced.teacherWeights[next], 3);
    final shared = LearnerSnapshot.fold(graph, 'learner', [
      event(1, 'a', first, 'pin'),
      event(2, 'b', first, 'pin'),
      event(3, 'a', next, 'replace'),
    ]);
    expect(shared.teacherWeights[first], 3);
    expect(shared.teacherWeights[next], 3);
  });
}
