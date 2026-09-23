import 'events.dart';
import 'learning.dart';

class SkillEvidence {
  final Skill skill;
  final int observedNodes, totalNodes, observations;
  final double? mean;
  const SkillEvidence(
    this.skill,
    this.observedNodes,
    this.totalNodes,
    this.observations,
    this.mean,
  );
}

/// Counts evidence, not elapsed sessions or fabricated confidence intervals.
/// Time-window counts use HLC timestamps; future-dated events are excluded.
class LearnerProgress {
  final List<SkillEvidence> skills;
  final List<SkillNode> weaknesses;
  final List<DomainEvent> recent;
  final int attemptsThisWeek, activeDaysThisWeek;
  LearnerProgress._(
    this.skills,
    this.weaknesses,
    this.recent,
    this.attemptsThisWeek,
    this.activeDaysThisWeek,
  );
  factory LearnerProgress.from(
    SkillGraph graph,
    String learner,
    Iterable<DomainEvent> source, {
    required DateTime now,
    Duration dayOffset = Duration.zero,
  }) {
    final state = LearnerSnapshot.fold(graph, learner, source);
    final observed = state.mastery;
    final skills = [
      for (final skill in Skill.values) _skill(graph, observed, skill),
    ];
    final weaknesses =
        graph.nodes.values
            .where(
              (n) =>
                  (observed[n.id]?.observations ?? 0) > 0 &&
                  observed[n.id]!.learned < .85,
            )
            .toList()
          ..sort((a, b) {
            final order = observed[a.id]!.learned.compareTo(
              observed[b.id]!.learned,
            );
            return order == 0 ? a.id.compareTo(b.id) : order;
          });
    final ids = state.evidenceIds.toSet();
    final events =
        {
          for (final event in source)
            if (event.learnerId == learner && ids.contains(event.id))
              event.id: event,
        }.values.toList()..sort((a, b) {
          final order = b.hlc.compareTo(a.hlc);
          return order == 0 ? b.id.compareTo(a.id) : order;
        });
    final lower = now.subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    final week = events
        .where(
          (e) =>
              e.hlc.millis >= lower &&
              e.hlc.millis <= now.millisecondsSinceEpoch,
        )
        .toList();
    final days = week.map((e) {
      final at = DateTime.fromMillisecondsSinceEpoch(
        e.hlc.millis,
        isUtc: true,
      ).add(dayOffset);
      return '${at.year}-${at.month}-${at.day}';
    }).toSet();
    return LearnerProgress._(
      List.unmodifiable(skills),
      List.unmodifiable(weaknesses.take(3)),
      List.unmodifiable(events.take(5)),
      week.length,
      days.length,
    );
  }
  static SkillEvidence _skill(
    SkillGraph graph,
    Map<String, Mastery> states,
    Skill skill,
  ) {
    final nodes = graph.nodes.values.where((n) => n.skill == skill).toList();
    final observed = nodes
        .map((n) => states[n.id])
        .whereType<Mastery>()
        .where((m) => m.observations > 0)
        .toList();
    return SkillEvidence(
      skill,
      observed.length,
      nodes.length,
      observed.fold(0, (n, m) => n + m.observations),
      observed.isEmpty
          ? null
          : observed.map((m) => m.learned).reduce((a, b) => a + b) /
                observed.length,
    );
  }
}
