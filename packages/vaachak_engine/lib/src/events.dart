import 'dart:convert';
import 'learning.dart';

String canonicalEventJson(dynamic value) {
  dynamic canonical(dynamic v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: canonical(v[key])};
    }
    if (v is List) return v.map(canonical).toList();
    return v;
  }

  return jsonEncode(canonical(value));
}

dynamic _freezeJson(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map((k, v) => MapEntry(k as String, _freezeJson(v))),
    );
  }
  if (value is List) return List<dynamic>.unmodifiable(value.map(_freezeJson));
  return value;
}

class HybridClock implements Comparable<HybridClock> {
  final int millis, counter;
  final String device;
  HybridClock(this.millis, this.counter, this.device) {
    if (millis < 0 ||
        millis > 9999999999999 ||
        counter < 0 ||
        counter > 999999 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(device)) {
      throw ArgumentError('Invalid hybrid clock');
    }
  }
  factory HybridClock.parse(String value) {
    final m = RegExp(
      r'^(\d{13}):(\d{6}):([A-Za-z0-9_-]{1,80})$',
    ).firstMatch(value);
    if (m == null) {
      throw FormatException('Invalid HLC');
    }
    return HybridClock(int.parse(m[1]!), int.parse(m[2]!), m[3]!);
  }
  HybridClock tick(int now, [HybridClock? remote]) {
    final max = [
      now,
      millis,
      remote?.millis ?? 0,
    ].reduce((a, b) => a > b ? a : b);
    final next = max == millis && max == remote?.millis
        ? (counter > remote!.counter ? counter : remote.counter) + 1
        : max == millis
        ? counter + 1
        : max == remote?.millis
        ? remote!.counter + 1
        : 0;
    return next > 999999
        ? HybridClock(max + 1, 0, device)
        : HybridClock(max, next, device);
  }

  @override
  String toString() =>
      '${millis.toString().padLeft(13, '0')}:${counter.toString().padLeft(6, '0')}:$device';
  @override
  int compareTo(HybridClock other) => toString().compareTo(other.toString());
}

const eventTypes = {
  'ProfileCreated',
  'ProfileUpdated',
  'ConsentGranted',
  'ConsentRevoked',
  'AssessmentStarted',
  'AssessmentItemAnswered',
  'AssessmentCompleted',
  'PracticeAttempt',
  'ReadingAttemptScored',
  'ReadingAttemptUnscored',
  'WordFlagged',
  'WordRepeated',
  'WordCleared',
  'SentenceSubmitted',
  'CorrectionShown',
  'RuleExplained',
  'SessionStarted',
  'SessionEnded',
  'PathRebuilt',
  'InterventionApplied',
  'LearnerErased',
  'TeacherIntervention',
};

class DomainEvent {
  final String id, learnerId, deviceId, type;
  final int seq, version;
  final HybridClock hlc;
  final Map<String, dynamic> payload;
  DomainEvent({
    required this.id,
    required this.learnerId,
    required this.deviceId,
    required this.seq,
    required this.hlc,
    required this.type,
    this.version = 1,
    required Map<String, dynamic> payload,
  }) : payload =
           _freezeJson(jsonDecode(jsonEncode(payload)))
               as Map<String, dynamic> {
    if (!RegExp(r'^[0-7][0-9A-HJKMNP-TV-Z]{25}$').hasMatch(id) ||
        learnerId.isEmpty ||
        learnerId.length > 80 ||
        deviceId != hlc.device ||
        seq < 1 ||
        version != 1 ||
        !eventTypes.contains(type)) {
      throw FormatException('Invalid event envelope');
    }
    if (utf8.encode(jsonEncode(payload)).length > 32768) {
      throw FormatException('Event payload exceeds 32 KiB');
    }
    void rejectAudio(dynamic value) {
      if (value is Map) {
        for (final entry in value.entries) {
          if (RegExp(
            r'^(audio|pcm|samples|rawAudio|recording|transcript)$',
            caseSensitive: false,
          ).hasMatch(entry.key.toString())) {
            throw FormatException('Raw voice data is not permitted in events');
          }
          rejectAudio(entry.value);
        }
      } else if (value is List) {
        for (final item in value) {
          rejectAudio(item);
        }
      }
    }

    rejectAudio(this.payload);
    if (type == 'PracticeAttempt' || type == 'AssessmentItemAnswered') {
      if (payload['nodeId'] is! String ||
          payload['itemId'] is! String ||
          payload['score'] is! num) {
        throw FormatException('Missing observation fields');
      }
      probability((payload['score'] as num).toDouble(), 'score');
    }
    if (type.startsWith('Consent')) {
      if (!{
        'core',
        'microphone',
        'clipRetention',
        'serverSync',
        'telemetry',
      }.contains(payload['purpose'])) {
        throw FormatException('Invalid consent purpose');
      }
    }
  }
  factory DomainEvent.fromJson(Map<String, dynamic> j) {
    const keys = {
      'id',
      'learnerId',
      'deviceId',
      'seq',
      'hlc',
      'type',
      'v',
      'payload',
    };
    if (j.keys.toSet().difference(keys).isNotEmpty ||
        !j.keys.toSet().containsAll(keys)) {
      throw FormatException('Unexpected event fields');
    }
    return DomainEvent(
      id: j['id'] as String,
      learnerId: j['learnerId'] as String,
      deviceId: j['deviceId'] as String,
      seq: j['seq'] as int,
      hlc: HybridClock.parse(j['hlc'] as String),
      type: j['type'] as String,
      version: j['v'] as int,
      payload: (j['payload'] as Map).cast<String, dynamic>(),
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'learnerId': learnerId,
    'deviceId': deviceId,
    'seq': seq,
    'hlc': hlc.toString(),
    'type': type,
    'v': version,
    'payload': payload,
  };
}

class LearnerSnapshot {
  final Map<String, Mastery> mastery;
  final Map<String, DifficultyLadder> ladders;
  final Map<String, double> teacherWeights;
  final Map<String, bool> consents;
  final List<String> evidenceIds;
  final bool erased;
  LearnerSnapshot(
    this.mastery,
    this.ladders,
    this.teacherWeights,
    this.consents,
    this.evidenceIds,
    this.erased,
  );
  factory LearnerSnapshot.fold(
    SkillGraph graph,
    String learner,
    Iterable<DomainEvent> source,
  ) {
    final byId = <String, DomainEvent>{};
    for (final e in source.where((e) => e.learnerId == learner)) {
      final old = byId[e.id];
      if (old != null &&
          canonicalEventJson(old.toJson()) != canonicalEventJson(e.toJson())) {
        throw StateError('Conflicting event ID');
      }
      byId[e.id] = e;
    }
    final events = byId.values.toList()
      ..sort((a, b) {
        final c = a.hlc.compareTo(b.hlc);
        return c == 0 ? a.id.compareTo(b.id) : c;
      });
    if (events.any((e) => e.type == 'LearnerErased')) {
      return LearnerSnapshot({}, {}, {}, {}, [], true);
    }
    final states = <String, Mastery>{},
        ladders = <String, DifficultyLadder>{},
        weights = <String, double>{},
        consents = <String, bool>{},
        evidence = <String>[];
    final teacherSources = <String, Map<String, double>>{};
    for (final e in events) {
      if (e.type == 'PracticeAttempt' || e.type == 'AssessmentItemAnswered') {
        final id = e.payload['nodeId'] as String, node = graph.nodes[id];
        if (node == null) {
          throw StateError('Unknown skill node $id');
        }
        final score = (e.payload['score'] as num).toDouble();
        states[id] = (states[id] ?? Mastery(learned: node.bkt.prior)).observe(
          score,
          node.bkt,
          DateTime.fromMillisecondsSinceEpoch(e.hlc.millis, isUtc: true),
        );
        ladders[id] = (ladders[id] ?? const DifficultyLadder()).observe(score);
        evidence.add(e.id);
      }
      if (e.type == 'ConsentGranted' || e.type == 'ConsentRevoked') {
        consents[e.payload['purpose'] as String] = e.type == 'ConsentGranted';
      }
      if (e.type == 'TeacherIntervention') {
        final node = e.payload['nodeId'] as String;
        if (!graph.nodes.containsKey(node)) {
          throw StateError('Unknown intervention node');
        }
        final source = '${e.payload['classId']}:${e.payload['teacherId']}';
        final sourceWeights = teacherSources.putIfAbsent(node, () => {});
        final kind = e.payload['kind'];
        if (kind == 'replace') {
          for (final weights in teacherSources.values) {
            weights[source] = 0;
          }
          sourceWeights[source] = 3;
        }
        if (kind == 'pin' || kind == 'assign') {
          sourceWeights[source] = 3;
        }
        if (kind == 'unpin') {
          sourceWeights[source] = 0;
        }
        if (kind == 'approve') {
          sourceWeights[source] = 1;
        }
      }
    }
    for (final entry in teacherSources.entries) {
      if (entry.value.isNotEmpty) {
        weights[entry.key] = entry.value.values.reduce((a, b) => a > b ? a : b);
      }
    }
    return LearnerSnapshot(
      Map.unmodifiable(states),
      Map.unmodifiable(ladders),
      Map.unmodifiable(weights),
      Map.unmodifiable(consents),
      List.unmodifiable(evidence),
      false,
    );
  }
}
