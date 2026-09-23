import 'dart:convert';
import 'reading.dart';
export 'reading.dart';
import 'package:vaachak_engine/vaachak_engine.dart';

class ContentItem {
  final String id, nodeId, prompt, cefr, reviewStatus;
  final bool approved;
  final int version, difficulty, answer;
  final List<String> options;
  final Set<AgeBand> ages;
  ContentItem.fromJson(Map<String, dynamic> j)
    : approved =
          j['reviewStatus'] == 'approved' &&
          j['reviewer'] is String &&
          (j['reviewer'] as String).trim().isNotEmpty &&
          j['reviewedAt'] is String &&
          DateTime.tryParse(j['reviewedAt'] as String) != null,
      id = j['id'] as String,
      nodeId = j['nodeId'] as String,
      prompt = j['prompt'] as String,
      cefr = j['cefr'] as String,
      reviewStatus = j['reviewStatus'] as String,
      version = j['version'] as int,
      difficulty = j['difficulty'] as int,
      answer = j['answer'] as int,
      options = List.unmodifiable((j['options'] as List).cast<String>()),
      ages = Set.unmodifiable(
        (j['ageBands'] as List).map((a) => AgeBand.values.byName(a as String)),
      ) {
    if (j['type'] != 'choice' ||
        id.isEmpty ||
        prompt.trim().isEmpty ||
        version < 1 ||
        difficulty < 0 ||
        difficulty > 4 ||
        answer < 0 ||
        answer >= options.length ||
        options.length < 2 ||
        options.toSet().length != options.length ||
        ages.isEmpty ||
        !{'Pre-A1', 'A1', 'A2', 'B1', 'B2'}.contains(cefr) ||
        !{'draft', 'approved', 'rejected'}.contains(reviewStatus)) {
      throw FormatException('Invalid content item $id');
    }
  }
  double grade(int choice) {
    if (choice < 0 || choice >= options.length) {
      throw ArgumentError('Invalid answer');
    }
    return choice == answer ? 1 : 0;
  }
}

class ContentBank {
  final SkillGraph graph;
  final GrammarEngine grammar;
  final List<ContentItem> items;
  final List<ReadingPassage> passages;
  ContentBank(
    this.graph,
    this.grammar,
    Iterable<ContentItem> items, {
    Iterable<ReadingPassage> passages = const [],
  }) : items = List.unmodifiable(items),
       passages = List.unmodifiable(passages) {
    final ids = <String>{};
    for (final item in this.items) {
      if (!ids.add('${item.id}@${item.version}') ||
          !graph.nodes.containsKey(item.nodeId)) {
        throw FormatException('Duplicate item or unknown node');
      }
    }
    final passageIds = <String>{};
    for (final passage in this.passages) {
      if (!passageIds.add('${passage.id}@${passage.version}') ||
          graph.nodes[passage.nodeId]?.skill != Skill.reading ||
          ids.contains('${passage.id}@${passage.version}')) {
        throw FormatException('Duplicate passage or invalid reading node');
      }
    }
    for (final rule in grammar.rules) {
      if (!graph.nodes.containsKey(rule.nodeId)) {
        throw FormatException('Unknown grammar node');
      }
    }
  }
  factory ContentBank.decode(
    String graph,
    String rules,
    String items, {
    String passages = '[]',
  }) => ContentBank(
    SkillGraph(
      (jsonDecode(graph) as List).map(
        (j) => SkillNode.fromJson(j as Map<String, dynamic>),
      ),
    ),
    GrammarEngine(
      (jsonDecode(rules) as List).map(
        (j) => GrammarRule.fromJson(j as Map<String, dynamic>),
      ),
    ),
    (jsonDecode(items) as List)
        .map((j) => ContentItem.fromJson(j as Map<String, dynamic>))
        .toList(),
    passages: (jsonDecode(passages) as List).map(
      (j) => ReadingPassage.fromJson(j as Map<String, dynamic>),
    ),
  );
  List<String> releaseIssues() {
    final errors = <String>[
      for (final passage in passages)
        if (!passage.approved)
          'Reading passage ${passage.id} requires educator sign-off',
      for (final rule in grammar.rules)
        if (!rule.approved)
          'Grammar rule ${rule.id} requires educator sign-off',
    ];
    for (final node in graph.nodes.values) {
      for (var rung = 0; rung < 5; rung++) {
        for (final age in node.ages) {
          final count = node.skill == Skill.reading
              ? passages
                    .where(
                      (p) =>
                          p.nodeId == node.id &&
                          p.difficulty == rung &&
                          p.ages.contains(age) &&
                          p.approved,
                    )
                    .length
              : items
                    .where(
                      (i) =>
                          i.nodeId == node.id &&
                          i.difficulty == rung &&
                          i.ages.contains(age) &&
                          i.approved,
                    )
                    .length;
          if (count < 3) {
            errors.add(
              '${node.id} / rung $rung / ${age.name}: $count approved items; need 3',
            );
          }
        }
      }
    }
    return errors;
  }

  List<ContentItem> forNode(
    String node,
    AgeBand age, {
    bool allowDraft = false,
  }) => items
      .where(
        (i) =>
            i.nodeId == node &&
            i.ages.contains(age) &&
            (i.approved || allowDraft && i.reviewStatus == 'draft'),
      )
      .toList();
}
