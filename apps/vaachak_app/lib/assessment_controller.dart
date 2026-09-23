import 'dart:convert';
import 'dart:math' as math;
import 'package:vaachak_speech/vaachak_speech.dart';
import 'package:crypto/crypto.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/vaachak_store.dart';

/// Persists each answer and its completion marker in one transaction. The
/// run/ordinal pair is a command key: retrying a committed answer is a no-op.
class AssessmentController {
  final VaachakStore store;
  final ContentBank bank;
  final LocalProfile profile;
  AssessmentController(this.store, this.bank, this.profile);

  static const readingScoringPolicy = 'wordAccuracyTimesPaceV1';
  static const supported = {Skill.vocabulary, Skill.grammar, Skill.sentence};
  List<ContentItem> pool(Skill skill) {
    if (!supported.contains(skill)) return [];
    final result =
        bank.items
            .where(
              (i) =>
                  bank.graph.nodes[i.nodeId]!.skill == skill &&
                  bank.graph.nodes[i.nodeId]!.ages.contains(profile.age) &&
                  i.ages.contains(profile.age) &&
                  i.approved,
            )
            .toList()
          ..sort((a, b) {
            final order = a.id.compareTo(b.id);
            return order == 0 ? b.version.compareTo(a.version) : order;
          });
    // An updated version of a question is not independent assessment evidence.
    final seen = <String>{};
    return result.where((i) => seen.add(i.id)).toList();
  }

  List<ReadingPassage> get readingPool {
    final result =
        bank.passages
            .where(
              (p) =>
                  p.approved &&
                  p.ages.contains(profile.age) &&
                  bank.graph.nodes[p.nodeId]!.ages.contains(profile.age),
            )
            .toList()
          ..sort((a, b) {
            final order = a.id.compareTo(b.id);
            return order == 0 ? b.version.compareTo(a.version) : order;
          });
    final seen = <String>{};
    return result.where((p) => seen.add(p.id)).toList();
  }

  ReadingPassage? nextReading(SkillAssessment run) {
    if (run.skill != Skill.reading ||
        run.complete ||
        run.bankDigest != digest(Skill.reading)) {
      return null;
    }
    for (final passage in readingPool) {
      if (passage.difficulty == run.staircase.difficulty &&
          !run.usedItems.contains(passage.id)) {
        return passage;
      }
    }
    return null;
  }

  String digest(Skill skill) => sha256
      .convert(
        utf8.encode(
          canonicalEventJson(
            skill == Skill.reading
                ? {
                    'scoringPolicy': readingScoringPolicy,
                    'ageBand': profile.age.name,
                    'passages': readingPool
                        .map((p) => p.assessmentIdentity)
                        .toList(),
                  }
                : [
                    for (final i in pool(skill))
                      {
                        'id': i.id,
                        'version': i.version,
                        'nodeId': i.nodeId,
                        'difficulty': i.difficulty,
                        'prompt': i.prompt,
                        'options': i.options,
                        'answer': i.answer,
                      },
                  ],
          ),
        ),
      )
      .toString();

  Future<Map<Skill, SkillAssessment>> load() async =>
      SkillAssessment.fold(profile.id, await store.events(profile.id));

  String? unavailable(Skill skill, SkillAssessment? run) {
    if (!supported.contains(skill) && skill != Skill.reading) {
      return 'This skill needs a validated audio or reading assessment activity. It remains unassessed.';
    }
    if (run != null && !run.complete) {
      if (run.deviceId != store.deviceId) {
        return 'Continue on the device where this check started, or start a new check here.';
      }
      if (run.bankDigest != digest(skill)) {
        return 'The question pack changed. Install the original pack to resume, or start a new check.';
      }
      if (skill == Skill.reading
          ? nextReading(run) == null
          : next(run) == null) {
        return 'No unused reviewed question is available at level ${run.staircase.difficulty + 1}. Progress is saved; install a fuller reviewed pack to start a new check.';
      }
      return null;
    }
    if (skill == Skill.reading
        ? !readingPool.any((p) => p.difficulty == 2)
        : !pool(skill).any((i) => i.difficulty == 2)) {
      return skill == Skill.reading
          ? 'Install reviewed reading passages for the middle difficulty. It remains unassessed.'
          : 'Install reviewed questions for the middle difficulty to begin this check.';
    }
    return null;
  }

  ContentItem? next(SkillAssessment run) {
    if (run.complete || run.bankDigest != digest(run.skill)) return null;
    for (final item in pool(run.skill)) {
      if (item.difficulty == run.staircase.difficulty &&
          !run.usedItems.contains(item.id)) {
        return item;
      }
    }
    return null;
  }

  Future<void> _requireConsent(List<DomainEvent> events) async {
    final state = LearnerSnapshot.fold(bank.graph, profile.id, events);
    if (state.erased || state.consents['core'] != true) {
      throw StateError('Core learning consent is required');
    }
  }

  Future<SkillAssessment> begin(Skill skill, {bool restart = false}) =>
      store.transaction(() async {
        final history = await store.events(profile.id);
        await _requireConsent(history);
        final existing = SkillAssessment.fold(profile.id, history)[skill];
        if (!restart && existing != null) return existing;
        final reason = unavailable(skill, null);
        if (reason != null) throw StateError(reason);
        final event = await store.append(profile.id, 'AssessmentStarted', {
          'protocol': 1,
          'skill': skill.name,
          'ageBand': profile.age.name,
          'initialDifficulty': 2,
          'bankDigest': digest(skill),
        });
        return SkillAssessment.fold(profile.id, [...history, event])[skill]!;
      });

  Future<void> answer(
    SkillAssessment displayed,
    ContentItem item,
    int choice,
  ) => _answer(
    displayed,
    itemId: item.id,
    itemVersion: item.version,
    nodeId: item.nodeId,
    difficulty: item.difficulty,
    evidence: {'choice': choice, 'score': item.grade(choice)},
    matches: (run) => identical(next(run), item),
  );

  ReadingAssessmentEvidence evaluateReading(
    ReadingPassage passage,
    AudioClip clip,
    Transcript transcript,
  ) {
    if (!readingPool.contains(passage) ||
        !passage.assessmentModelIds.contains(transcript.modelId)) {
      throw StateError(
        'This speech model has not been approved for this reading check. No assessment score was saved.',
      );
    }
    final quality = SignalQuality.measure(clip);
    if (!quality.scorable ||
        clip.durationMs < 2000 ||
        transcript.words.isEmpty) {
      throw StateError(
        'This recording cannot be scored reliably. Try again; this passage remains unanswered.',
      );
    }
    final result = const ReadingAligner().score(
      passage.text,
      transcript.words,
      clip.durationMs,
      age: profile.age,
    );
    final score =
        result.accuracy * math.min(1.0, result.wcpm / passage.targetWcpm);
    return ReadingAssessmentEvidence._(passage, {
      'captureId': newUlid(),
      'score': score,
      'accuracy': result.accuracy,
      'wcpm': result.wcpm,
      'correctWords': result.correct,
      'durationMs': clip.durationMs,
      'modelId': transcript.modelId,
      'signalQuality': quality.toJson(),
      'scoringPolicy': readingScoringPolicy,
    });
  }

  Future<void> answerReading(
    SkillAssessment displayed,
    ReadingAssessmentEvidence reading,
  ) => _answer(
    displayed,
    itemId: reading.passage.id,
    itemVersion: reading.passage.version,
    nodeId: reading.passage.nodeId,
    difficulty: reading.passage.difficulty,
    evidence: reading.metrics,
    microphone: true,
    matches: (run) => identical(nextReading(run), reading.passage),
  );

  Future<void> _answer(
    SkillAssessment displayed, {
    required String itemId,
    required int itemVersion,
    required String nodeId,
    required int difficulty,
    required Map<String, dynamic> evidence,
    required bool Function(SkillAssessment) matches,
    bool microphone = false,
  }) => store.transaction(() async {
    final history = await store.events(profile.id);
    await _requireConsent(history);
    if (microphone &&
        LearnerSnapshot.fold(
              bank.graph,
              profile.id,
              history,
            ).consents['microphone'] !=
            true) {
      throw StateError('Microphone consent is required');
    }
    final run = SkillAssessment.fold(profile.id, history)[displayed.skill];
    if (run == null ||
        run.id != displayed.id ||
        run.deviceId != store.deviceId) {
      throw StateError('This assessment changed; reload before answering');
    }
    final ordinal = displayed.answers.length;
    if (run.answers.length > ordinal) {
      final old = run.answers[ordinal].payload;
      if (old['itemId'] == itemId &&
          old['itemVersion'] == itemVersion &&
          evidence.entries.every(
            (entry) =>
                canonicalEventJson(old[entry.key]) ==
                canonicalEventJson(entry.value),
          )) {
        return;
      }
      throw StateError('An answer for this step is already saved');
    }
    if (!matches(run) || ordinal != run.answers.length) {
      throw StateError('The question changed; reload before answering');
    }
    final event = await store.append(profile.id, 'AssessmentItemAnswered', {
      'assessmentId': run.id,
      'ordinal': ordinal,
      'skill': run.skill.name,
      'itemId': itemId,
      'itemVersion': itemVersion,
      'nodeId': nodeId,
      'difficulty': difficulty,
      ...evidence,
    });
    final updated = SkillAssessment.fold(profile.id, [
      ...history,
      event,
    ])[run.skill]!;
    if (updated.complete) {
      await store.append(profile.id, 'AssessmentCompleted', {
        'assessmentId': run.id,
        'skill': run.skill.name,
        'difficulty': updated.staircase.difficulty,
        'count': updated.answers.length,
      });
    }
  });
}

/// Keeps only numeric evidence in memory for retry after a failed save. Audio
/// and recognised words are deliberately absent. Only the evaluator creates it.
class ReadingAssessmentEvidence {
  final ReadingPassage passage;
  final Map<String, dynamic> metrics;
  ReadingAssessmentEvidence._(this.passage, Map<String, dynamic> metrics)
    : metrics = Map.unmodifiable({
        ...metrics,
        'signalQuality': Map<String, dynamic>.unmodifiable(
          metrics['signalQuality'] as Map<String, dynamic>,
        ),
      });
}
