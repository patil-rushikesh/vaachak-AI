import 'events.dart';
import 'learning.dart';

/// One skill's assessment. Answers, not a completion flag, determine progress.
/// A run belongs to its starting device; another device may display its history
/// but must start its own run instead of creating a competing answer branch.
class SkillAssessment {
  final DomainEvent started;
  final List<DomainEvent> answers;
  final AssessmentStaircase staircase;
  SkillAssessment._(this.started, this.answers, this.staircase);
  String get id => started.id;
  Skill get skill => Skill.values.byName(started.payload['skill'] as String);
  String get bankDigest => started.payload['bankDigest'] as String;
  String get deviceId => started.deviceId;
  bool get complete => staircase.complete;
  Set<String> get usedItems =>
      answers.map((e) => e.payload['itemId'] as String).toSet();

  static Map<Skill, SkillAssessment> fold(
    String learner,
    Iterable<DomainEvent> source,
  ) {
    final unique = <String, DomainEvent>{};
    for (final event in source.where((e) => e.learnerId == learner)) {
      final old = unique[event.id];
      if (old != null &&
          canonicalEventJson(old.toJson()) !=
              canonicalEventJson(event.toJson())) {
        throw StateError('Conflicting assessment event ID');
      }
      unique[event.id] = event;
    }
    final events = unique.values.toList()
      ..sort((a, b) {
        final order = a.hlc.compareTo(b.hlc);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    if (events.any((e) => e.type == 'LearnerErased')) return {};
    final runs = <String, SkillAssessment>{};
    final latest = <Skill, String>{};
    for (final e in events) {
      final p = e.payload;
      // Older observation-only assessment events are still valid mastery
      // evidence, but cannot claim to be a resumable run.
      if (e.type == 'AssessmentStarted' && p['protocol'] == 1) {
        final skill = Skill.values.byName(p['skill'] as String);
        AgeBand.values.byName(p['ageBand'] as String);
        if (p['bankDigest'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(p['bankDigest'] as String) ||
            p['initialDifficulty'] != 2) {
          throw StateError('Invalid assessment start');
        }
        runs[e.id] = SkillAssessment._(e, const [], AssessmentStaircase());
        latest[skill] = e.id;
      }
      if (e.type == 'AssessmentItemAnswered' && p['assessmentId'] != null) {
        final run = runs[p['assessmentId']];
        if (run == null ||
            run.complete ||
            e.deviceId != run.deviceId ||
            p['ordinal'] != run.answers.length ||
            p['skill'] != run.skill.name ||
            p['difficulty'] != run.staircase.difficulty ||
            p['itemVersion'] is! int ||
            (p['itemVersion'] as int) < 1 ||
            run.usedItems.contains(p['itemId'])) {
          throw StateError('Invalid assessment answer sequence');
        }
        runs[run.id] = SkillAssessment._(
          run.started,
          List.unmodifiable([...run.answers, e]),
          run.staircase.observe((p['score'] as num).toDouble()),
        );
      }
      if (e.type == 'AssessmentCompleted' && p['assessmentId'] != null) {
        final run = runs[p['assessmentId']];
        if (run == null ||
            !run.complete ||
            e.deviceId != run.deviceId ||
            p['difficulty'] != run.staircase.difficulty ||
            p['count'] != run.answers.length) {
          throw StateError('Completion without assessment evidence');
        }
      }
    }
    return Map.unmodifiable({
      for (final entry in latest.entries) entry.key: runs[entry.value]!,
    });
  }
}
