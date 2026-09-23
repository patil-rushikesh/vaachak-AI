import 'package:vaachak_engine/vaachak_engine.dart';

/// Rubric and model versions are part of the educator-reviewed passage.
class ReadingPassage {
  final String id, nodeId, title, text, cefr, reviewStatus;
  final int version, difficulty;
  final Set<AgeBand> ages;
  final Set<String> assessmentModelIds;
  final double targetWcpm;
  final bool approved;
  ReadingPassage.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      nodeId = j['nodeId'] as String,
      title = j['title'] as String,
      text = j['text'] as String,
      cefr = j['cefr'] as String,
      reviewStatus = j['reviewStatus'] as String,
      version = j['version'] as int,
      difficulty = j['difficulty'] as int,
      ages = Set.unmodifiable(
        (j['ageBands'] as List).map((a) => AgeBand.values.byName(a as String)),
      ),
      assessmentModelIds = Set.unmodifiable(
        (j['assessmentModelIds'] as List).cast<String>(),
      ),
      targetWcpm = (j['targetWcpm'] as num).toDouble(),
      approved =
          j['reviewStatus'] == 'approved' &&
          j['reviewer'] is String &&
          (j['reviewer'] as String).trim().isNotEmpty &&
          j['reviewedAt'] is String &&
          DateTime.tryParse(j['reviewedAt'] as String) != null {
    if (id.isEmpty ||
        nodeId.isEmpty ||
        title.trim().isEmpty ||
        text.trim().isEmpty ||
        text.length > 10000 ||
        normaliseWords(text).isEmpty ||
        normaliseWords(text).length > 500 ||
        version < 1 ||
        difficulty < 0 ||
        difficulty > 4 ||
        ages.isEmpty ||
        !{'Pre-A1', 'A1', 'A2', 'B1', 'B2'}.contains(cefr) ||
        !{'draft', 'approved', 'rejected'}.contains(reviewStatus) ||
        !targetWcpm.isFinite ||
        targetWcpm <= 0 ||
        targetWcpm > 300 ||
        assessmentModelIds.any(
          (id) => !RegExp(
            r'^[a-z0-9][a-z0-9._-]{0,99}@\d+\.\d+\.\d+$',
          ).hasMatch(id),
        ) ||
        (approved && assessmentModelIds.isEmpty)) {
      throw FormatException('Invalid reading passage $id');
    }
  }

  Map<String, dynamic> get assessmentIdentity => {
    'id': id,
    'version': version,
    'nodeId': nodeId,
    'title': title,
    'text': text,
    'difficulty': difficulty,
    'targetWcpm': targetWcpm,
    'assessmentModelIds': assessmentModelIds.toList()..sort(),
  };
}
