import 'learning.dart';

class GrammarRule {
  final String id, nodeId, pattern, replacement, explanation;
  final List<String> practice;
  final RegExp matcher;
  final bool approved;
  GrammarRule({
    required this.id,
    required this.nodeId,
    required this.pattern,
    required this.replacement,
    required this.explanation,
    required this.practice,
    this.approved = false,
  }) : matcher = RegExp(pattern, caseSensitive: false) {
    if (practice.length < 2 || pattern.length > 512 || id.isEmpty) {
      throw ArgumentError('Invalid grammar rule');
    }
  }
  factory GrammarRule.fromJson(Map<String, dynamic> j) => GrammarRule(
    approved:
        j['reviewStatus'] == 'approved' &&
        j['reviewer'] is String &&
        (j['reviewer'] as String).trim().isNotEmpty &&
        j['reviewedAt'] is String,
    id: j['id'] as String,
    nodeId: j['nodeId'] as String,
    pattern: j['pattern'] as String,
    replacement: j['replacement'] as String,
    explanation: j['explanation'] as String,
    practice: (j['practice'] as List).cast<String>(),
  );
}

class GrammarCorrection {
  final GrammarRule rule;
  final String original, corrected, correctedForm;
  GrammarCorrection(
    this.rule,
    this.original,
    this.corrected,
    this.correctedForm,
  );
  String template(AgeBand age) => age == AgeBand.child
      ? 'Try "$correctedForm". ${rule.explanation}'
      : '${rule.explanation} Use "$correctedForm".';
}

class GrammarEngine {
  final List<GrammarRule> rules;
  GrammarEngine(Iterable<GrammarRule> rules)
    : rules = List.unmodifiable(rules) {
    if (this.rules.map((r) => r.id).toSet().length != this.rules.length) {
      throw ArgumentError('Duplicate grammar rule IDs');
    }
  }
  GrammarCorrection? check(String sentence) {
    if (sentence.length > 2000) {
      throw ArgumentError('Sentence exceeds 2,000 characters');
    }
    for (final rule in rules) {
      final match = rule.matcher.firstMatch(sentence);
      if (match == null) {
        continue;
      }
      var replacement = rule.replacement.replaceAllMapped(
        RegExp(r'\$(\d+)'),
        (m) => match.group(int.parse(m[1]!)) ?? '',
      );
      final original = match.group(0)!;
      if (original.isNotEmpty && original[0] == original[0].toUpperCase()) {
        replacement = replacement[0].toUpperCase() + replacement.substring(1);
      }
      return GrammarCorrection(
        rule,
        sentence,
        sentence.replaceRange(match.start, match.end, replacement),
        replacement,
      );
    }
    return null;
  }
}
