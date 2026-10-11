import 'dart:io';
import 'package:test/test.dart';
import 'package:vaachak_content/vaachak_content.dart';

void main() {
  test('seed bank loads but cannot pass production content gate', () {
    String asset(String n) => File('../../content/$n.json').readAsStringSync();
    final bank = ContentBank.decode(
      asset('skill_graph'),
      asset('grammar_rules'),
      asset('items'),
    );
    expect(bank.items.length, 15);
    expect(bank.releaseIssues(), isNotEmpty);
    expect(
      bank.forNode(
        'vocabulary.frequent_500',
        bank.graph.nodes.values.first.ages.first,
      ),
      isEmpty,
    );
  });
  Map<String, dynamic> question() => {
    'id': 'test',
    'version': 1,
    'type': 'choice',
    'nodeId': 'node',
    'prompt': 'Test',
    'cefr': 'A1',
    'reviewStatus': 'approved',
    'difficulty': 2,
    'answer': 0,
    'options': ['A', 'B'],
    'ageBands': ['adult'],
  };
  test('approval requires named educator and parseable date', () {
    expect(ContentItem.fromJson(question()).approved, isFalse);
    expect(
      ContentItem.fromJson({
        ...question(),
        'reviewer': 'Educator',
        'reviewedAt': 'invalid',
      }).approved,
      isFalse,
    );
    expect(
      ContentItem.fromJson({
        ...question(),
        'reviewer': 'Educator',
        'reviewedAt': '2026-09-23',
      }).approved,
      isTrue,
    );
  });
  test('non-choice modality cannot be silently parsed as choice evidence', () {
    expect(
      () => ContentItem.fromJson({...question(), 'type': 'speaking'}),
      throwsFormatException,
    );
  });
  Map<String, dynamic> passage() => {
    'id': 'reading.test',
    'version': 1,
    'nodeId': 'reading.letters',
    'title': 'Test',
    'text': 'We read a book.',
    'difficulty': 2,
    'cefr': 'A1',
    'ageBands': ['adult'],
    'targetWcpm': 60,
    'assessmentModelIds': ['test.asr@1.0.0'],
    'reviewStatus': 'approved',
    'reviewer': 'Test only',
    'reviewedAt': '2026-09-23',
  };
  test('reading passage requires bounded text and a valid reviewed rubric', () {
    expect(ReadingPassage.fromJson(passage()).approved, isTrue);
    for (final change in [
      {'text': '!!!'},
      {'text': 'word ' * 501},
      {'targetWcpm': 0},
      {'targetWcpm': double.infinity},
      {'assessmentModelIds': <String>[]},
      {
        'assessmentModelIds': ['unversioned'],
      },
      {'ageBands': <String>[]},
    ]) {
      expect(
        () => ReadingPassage.fromJson({...passage(), ...change}),
        throwsFormatException,
      );
    }
  });
  test('reading passages require reading nodes and immutable content', () {
    String asset(String n) => File('../../content/$n.json').readAsStringSync();
    final bank = ContentBank.decode(
      asset('skill_graph'),
      asset('grammar_rules'),
      asset('items'),
      passages: asset('passages'),
    );
    expect(bank.passages.single.approved, isFalse);
    expect(() => bank.passages.clear(), throwsUnsupportedError);
    expect(() => bank.passages.single.ages.clear(), throwsUnsupportedError);
    expect(
      () => ContentBank(
        bank.graph,
        bank.grammar,
        [],
        passages: [
          ReadingPassage.fromJson({...passage(), 'nodeId': 'grammar.articles'}),
        ],
      ),
      throwsFormatException,
    );
  });
}
