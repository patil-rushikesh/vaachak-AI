import 'package:flutter/foundation.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/vaachak_store.dart';

class LearningSession extends ChangeNotifier {
  final VaachakStore store;
  final ContentBank bank;
  final LocalProfile profile;
  late LearnerSnapshot snapshot;
  List<DomainEvent> history = const [];
  bool ready = false, _disposed = false;
  Future<void>? _ending;
  final DateTime startedAt = DateTime.now();
  LearningSession(this.store, this.bank, this.profile);

  void _active() {
    if (_disposed || !ready) throw StateError('Session is locked');
  }

  LearnerSnapshot _consented(List<DomainEvent> events) {
    final result = LearnerSnapshot.fold(bank.graph, profile.id, events);
    if (result.consents['core'] != true || result.erased) {
      throw StateError('Core learning consent is required');
    }
    return result;
  }

  Future<void> start() async {
    if (_disposed || ready) throw StateError('Session cannot be started');
    final events = await store.transaction(() async {
      final previous = await store.events(profile.id);
      _consented(previous);
      if (_disposed) throw StateError('Session is locked');
      final started = await store.append(profile.id, 'SessionStarted', {});
      if (_disposed) throw StateError('Session is locked');
      return [...previous, started];
    });
    if (_disposed) return;
    history = List.unmodifiable(events);
    snapshot = _consented(events);
    ready = true;
    notifyListeners();
  }

  Future<void> reloadProgress() async {
    final events = await store.events(profile.id);
    if (_disposed || !ready) return;
    history = List.unmodifiable(events);
    snapshot = LearnerSnapshot.fold(bank.graph, profile.id, events);
    if (snapshot.erased || snapshot.consents['core'] != true) ready = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ready = false;
    super.dispose();
  }

  List<Recommendation> get path => !ready
      ? []
      : PathPlanner().plan(
          bank.graph,
          snapshot.mastery,
          profile.age,
          DateTime.now(),
          teacherWeights: snapshot.teacherWeights,
          eligibleNodeIds: bank.graph.nodes.keys
              .where((id) => items(id).isNotEmpty)
              .toSet(),
        );
  List<ContentItem> items(String node) => bank.forNode(
    node,
    profile.age,
    allowDraft: const bool.fromEnvironment('ALLOW_DRAFT_CONTENT'),
  );

  /// A UI step keeps its command ID until saving and refresh succeed. A retry
  /// returns the committed result rather than adding another BKT observation.
  Future<void> answer(ContentItem item, int choice, {String? attemptId}) async {
    _active();
    if (!items(item.nodeId).contains(item)) {
      throw StateError('Question is unavailable');
    }
    final command = attemptId ?? newUlid();
    final payload = <String, dynamic>{
      'attemptId': command,
      'itemId': item.id,
      'itemVersion': item.version,
      'nodeId': item.nodeId,
      'score': item.grade(choice),
      'choice': choice,
      'rung': item.difficulty,
      'hintsUsed': 0,
    };
    final events = await store.transaction(() async {
      final previous = await store.events(profile.id);
      _active();
      _consented(previous);
      final duplicate = previous.where(
        (e) => e.type == 'PracticeAttempt' && e.payload['attemptId'] == command,
      );
      if (duplicate.isNotEmpty) {
        if (canonicalEventJson(duplicate.single.payload) !=
            canonicalEventJson(payload)) {
          throw StateError('An answer is already saved for this step');
        }
        return previous;
      }
      final event = await store.append(profile.id, 'PracticeAttempt', payload);
      _active();
      return [...previous, event];
    });
    if (_disposed || !ready) return;
    history = List.unmodifiable(events);
    snapshot = _consented(events);
    notifyListeners();
  }

  Future<void> grammarViewed(GrammarCorrection correction) =>
      store.transaction(() async {
        _active();
        _consented(await store.events(profile.id));
        _active();
        await store.append(profile.id, 'CorrectionShown', {
          'ruleId': correction.rule.id,
          'source': 'rule',
        });
        _active();
      });

  Future<void> finish() {
    ready = false;
    return _ending ??= store
        .append(profile.id, 'SessionEnded', {
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
        })
        .then((_) {});
  }
}
