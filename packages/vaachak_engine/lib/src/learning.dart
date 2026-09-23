import 'dart:math' as math;

enum Skill {
  vocabulary,
  grammar,
  sentence,
  reading,
  pronunciation,
  listening,
  speaking,
}

enum AgeBand { child, student, adult }

void probability(double value, String name) {
  if (!value.isFinite || value < 0 || value > 1) {
    throw ArgumentError.value(
      value,
      name,
      'Must be finite and between 0 and 1',
    );
  }
}

class BktParameters {
  final double prior, transition, guess, slip;
  BktParameters({
    this.prior = .3,
    this.transition = .1,
    this.guess = .2,
    this.slip = .1,
  }) {
    for (final v in [prior, transition, guess, slip]) {
      probability(v, 'BKT parameter');
    }
    if (guess == 0 || guess == 1 || slip == 0 || slip == 1) {
      throw ArgumentError('Guess and slip must be strictly between 0 and 1');
    }
  }
  factory BktParameters.fromJson(Map<String, dynamic> j) => BktParameters(
    prior: (j['prior'] as num?)?.toDouble() ?? .3,
    transition: (j['transition'] as num?)?.toDouble() ?? .1,
    guess: (j['guess'] as num?)?.toDouble() ?? .2,
    slip: (j['slip'] as num?)?.toDouble() ?? .1,
  );
}

class Mastery {
  final double learned;
  final int observations;
  final DateTime? lastObserved;
  final double trend;
  Mastery({
    this.learned = .3,
    this.observations = 0,
    this.lastObserved,
    this.trend = 0,
  }) {
    probability(learned, 'learned');
    if (observations < 0 || !trend.isFinite) {
      throw ArgumentError('Invalid mastery');
    }
  }
  String get band => observations == 0
      ? 'Not assessed'
      : learned >= .85 && observations >= 5
      ? 'Strong'
      : learned >= .5
      ? 'Moderate'
      : 'Developing';
  Mastery observe(double score, BktParameters p, DateTime at) {
    probability(score, 'score');
    final correct =
        learned *
        (1 - p.slip) /
        (learned * (1 - p.slip) + (1 - learned) * p.guess);
    final incorrect =
        learned * p.slip / (learned * p.slip + (1 - learned) * (1 - p.guess));
    final posterior = score * correct + (1 - score) * incorrect;
    final next = posterior + (1 - posterior) * p.transition;
    return Mastery(
      learned: next,
      observations: observations + 1,
      lastObserved: at,
      trend: next - learned,
    );
  }

  Map<String, dynamic> toJson() => {
    'learned': learned,
    'observations': observations,
    'lastObserved': lastObserved?.toUtc().toIso8601String(),
    'trend': trend,
  };
}

class SkillNode {
  final String id, name, cefr;
  final Skill skill;
  final int difficulty;
  final List<String> prerequisites;
  final Set<AgeBand> ages;
  final BktParameters bkt;
  final double relevance;
  SkillNode({
    required this.id,
    required this.name,
    required this.skill,
    required this.difficulty,
    required this.cefr,
    Iterable<String> prerequisites = const [],
    Set<AgeBand>? ages,
    BktParameters? bkt,
    this.relevance = 1,
  }) : prerequisites = List.unmodifiable(prerequisites),
       ages = Set.unmodifiable(ages ?? AgeBand.values.toSet()),
       bkt = bkt ?? BktParameters() {
    if (id.isEmpty ||
        name.isEmpty ||
        difficulty < 0 ||
        difficulty > 4 ||
        relevance < .5 ||
        relevance > 1 ||
        !relevance.isFinite) {
      throw ArgumentError('Invalid skill node $id');
    }
  }
  factory SkillNode.fromJson(Map<String, dynamic> j) => SkillNode(
    id: j['id'] as String,
    name: j['name'] as String,
    skill: Skill.values.byName(j['skill'] as String),
    difficulty: j['difficulty'] as int,
    cefr: j['cefr'] as String,
    prerequisites: (j['prerequisites'] as List).cast<String>(),
    ages: (j['ageBands'] as List)
        .map((a) => AgeBand.values.byName(a as String))
        .toSet(),
    bkt: BktParameters.fromJson(
      (j['bkt'] as Map?)?.cast<String, dynamic>() ?? {},
    ),
    relevance: (j['relevance'] as num?)?.toDouble() ?? 1,
  );
}

class SkillGraph {
  final Map<String, SkillNode> nodes;
  SkillGraph(Iterable<SkillNode> source)
    : nodes = Map.unmodifiable({for (final n in source) n.id: n}) {
    if (nodes.length != source.length || nodes.isEmpty) {
      throw ArgumentError('Empty graph or duplicate IDs');
    }
    final visiting = <String>{}, visited = <String>{};
    void visit(String id) {
      if (visited.contains(id)) {
        return;
      }
      if (!visiting.add(id)) {
        throw ArgumentError('Cycle at $id');
      }
      final node = nodes[id];
      if (node == null) {
        throw ArgumentError('Missing prerequisite $id');
      }
      for (final p in node.prerequisites) {
        visit(p);
      }
      visiting.remove(id);
      visited.add(id);
    }

    for (final id in nodes.keys) {
      visit(id);
    }
  }
  int blocks(String id) =>
      nodes.values.where((n) => n.prerequisites.contains(id)).length;
}

class Recommendation {
  final SkillNode node;
  final double score;
  final String reason;
  Recommendation(this.node, this.score, this.reason);
}

class PathPlanner {
  List<Recommendation> plan(
    SkillGraph graph,
    Map<String, Mastery> state,
    AgeBand age,
    DateTime now, {
    Map<String, double> teacherWeights = const {},
    int limit = 5,
    Set<String>? eligibleNodeIds,
  }) {
    if (limit < 1) {
      return [];
    }
    final candidates = <Recommendation>[];
    for (final n in graph.nodes.values) {
      if ((eligibleNodeIds != null && !eligibleNodeIds.contains(n.id)) ||
          !n.ages.contains(age) ||
          n.prerequisites.any(
            (p) => (state[p]?.learned ?? graph.nodes[p]!.bkt.prior) < .6,
          )) {
        continue;
      }
      final m = state[n.id] ?? Mastery(learned: n.bkt.prior);
      final weight = teacherWeights[n.id] ?? 1;
      if (!weight.isFinite || weight < 0) {
        throw ArgumentError('Invalid teacher weight');
      }
      if (weight == 0) {
        continue;
      }
      final days = m.lastObserved == null
          ? 3.0
          : math.max(0, now.difference(m.lastObserved!).inMilliseconds) /
                Duration.millisecondsPerDay;
      final recency = .4 + .6 * (days / 3).clamp(0, 1);
      final blocking = graph.blocks(n.id);
      final score =
          (1 - m.learned) *
          n.relevance *
          recency *
          (1 + .25 * blocking) *
          weight;
      candidates.add(
        Recommendation(
          n,
          score,
          '${m.observations == 0 ? 'Ready for a first check' : 'Mastery ${(m.learned * 100).round()}% from ${m.observations} attempts'}, supports $blocking next skills${weight >= 3 ? ', prioritised by your teacher' : ''}.',
        ),
      );
    }
    candidates.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c == 0 ? a.node.id.compareTo(b.node.id) : c;
    });
    final counts = <Skill, int>{}, result = <Recommendation>[];
    for (final candidate in candidates) {
      final skill = candidate.node.skill;
      if ((counts[skill] ?? 0) >= 2) {
        continue;
      }
      result.add(candidate);
      counts[skill] = (counts[skill] ?? 0) + 1;
      if (result.length == limit) {
        break;
      }
    }
    return result;
  }
}

class DifficultyLadder {
  final int rung, goodStreak, poorStreak;
  final bool workedExample;
  const DifficultyLadder({
    this.rung = 2,
    this.goodStreak = 0,
    this.poorStreak = 0,
    this.workedExample = false,
  });
  DifficultyLadder observe(double score) {
    probability(score, 'score');
    final good = score >= .8 ? goodStreak + 1 : 0,
        poor = score < .5 ? poorStreak + 1 : 0;
    if (good >= 3) {
      return DifficultyLadder(rung: math.min(4, rung + 1));
    }
    if (poor >= 2) {
      return DifficultyLadder(rung: math.max(0, rung - 1), workedExample: true);
    }
    return DifficultyLadder(rung: rung, goodStreak: good, poorStreak: poor);
  }

  String? prerequisiteToRevisit(SkillNode node, Map<String, Mastery> state) {
    if (!workedExample) {
      return null;
    }
    for (final p in node.prerequisites) {
      if ((state[p]?.learned ?? .3) < .5) {
        return p;
      }
    }
    return null;
  }
}

class AssessmentStaircase {
  final int difficulty;
  final List<bool> responses;
  AssessmentStaircase({this.difficulty = 2, List<bool> responses = const []})
    : responses = List.unmodifiable(responses);
  bool get complete {
    if (responses.length >= 8) {
      return true;
    }
    if (responses.length < 6) {
      return false;
    }
    final tail = responses.sublist(responses.length - 4);
    return tail[0] != tail[1] && tail[1] != tail[2] && tail[2] != tail[3];
  }

  AssessmentStaircase observe(double score) {
    probability(score, 'score');
    if (complete) {
      throw StateError('Assessment is complete');
    }
    final correct = score >= .7;
    return AssessmentStaircase(
      difficulty: (difficulty + (correct ? 1 : -1)).clamp(0, 4),
      responses: [...responses, correct],
    );
  }
}
