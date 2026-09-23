import 'dart:math' as math;
import 'learning.dart';

class SpokenWord {
  final String text;
  final int startMs, endMs;
  final double? confidence;
  const SpokenWord(this.text, this.startMs, this.endMs, {this.confidence});
}

enum ReadingErrorKind {
  omission,
  substitution,
  mispronunciation,
  repetition,
  insertion,
  hesitation,
}

class ReadingError {
  final int referenceIndex;
  final ReadingErrorKind kind;
  final String? hypothesis;
  final double distance;
  final bool needsConfirmation;
  const ReadingError(
    this.referenceIndex,
    this.kind, {
    this.hypothesis,
    this.distance = 1,
    this.needsConfirmation = false,
  });
  Map<String, dynamic> toJson() => {
    'refIdx': referenceIndex,
    'kind': kind.name,
    if (hypothesis != null) 'hyp': hypothesis,
    'phoneticDist': distance,
    'needsConfirmation': needsConfirmation,
  };
}

class ReadingScore {
  final int correct;
  final double wcpm, accuracy;
  final List<ReadingError> errors;
  final ReadingError? correction;
  ReadingScore(
    this.correct,
    this.wcpm,
    this.accuracy,
    this.errors,
    this.correction,
  );
}

List<String> normaliseWords(String text) {
  const contractions = {
    "can't": 'can not',
    "won't": 'will not',
    "don't": 'do not',
    "isn't": 'is not',
    "i'm": 'i am',
    "it's": 'it is',
    "we're": 'we are',
    "they're": 'they are',
    "didn't": 'did not',
  };
  var result = text.toLowerCase().replaceAll('’', "'");
  contractions.forEach((key, value) {
    result = result.replaceAll(RegExp('\\b$key\\b'), value);
  });
  const numbers = [
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
    'ten',
    'eleven',
    'twelve',
    'thirteen',
    'fourteen',
    'fifteen',
    'sixteen',
    'seventeen',
    'eighteen',
    'nineteen',
    'twenty',
  ];
  result = result.replaceAllMapped(RegExp(r'\b\d+\b'), (m) {
    final n = int.tryParse(m[0]!);
    return n != null && n < numbers.length ? numbers[n] : m[0]!;
  });
  return RegExp(
    r"[a-z0-9]+(?:'[a-z]+)?",
  ).allMatches(result).map((m) => m[0]!).toList();
}

class ReadingAligner {
  final Map<String, List<String>> lexicon;
  const ReadingAligner({this.lexicon = const {}});
  List<String> phones(String word) =>
      lexicon[word] ??
      word
          .replaceAll('ph', 'f')
          .replaceAll('ck', 'k')
          .replaceAll('qu', 'kw')
          .replaceAll(RegExp(r'e$'), '')
          .split('');
  double phoneticDistance(String a, String b) {
    final x = phones(a), y = phones(b);
    if (x.isEmpty || y.isEmpty) {
      return x.isEmpty && y.isEmpty ? 0 : 1;
    }
    var previous = List.generate(y.length + 1, (i) => i);
    for (var i = 1; i <= x.length; i++) {
      final current = List.filled(y.length + 1, 0)..[0] = i;
      for (var j = 1; j <= y.length; j++) {
        current[j] = [
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1),
        ].reduce(math.min);
      }
      previous = current;
    }
    return previous.last / math.max(x.length, y.length);
  }

  ReadingScore score(
    String reference,
    List<SpokenWord> input,
    int durationMs, {
    AgeBand age = AgeBand.student,
    double confidenceThreshold = .55,
    Map<String, int> recurrence = const {},
  }) {
    if (durationMs <= 0 || durationMs > 60000) {
      throw ArgumentError('Duration must be 1–60,000 ms');
    }
    final ref = normaliseWords(reference), hyp = <SpokenWord>[];
    for (final w in input) {
      if (w.startMs < 0 ||
          w.endMs < w.startMs ||
          w.endMs > durationMs ||
          (hyp.isNotEmpty && w.startMs < hyp.last.startMs)) {
        throw ArgumentError('Invalid word timing');
      }
      if (w.confidence != null) {
        probability(w.confidence!, 'confidence');
      }
      for (final token in normaliseWords(w.text)) {
        hyp.add(
          SpokenWord(token, w.startMs, w.endMs, confidence: w.confidence),
        );
      }
    }
    if (ref.isEmpty || ref.length > 500 || hyp.length > 700) {
      throw ArgumentError('Invalid transcript length');
    }
    final d = List.generate(
      ref.length + 1,
      (_) => List.filled(hyp.length + 1, 0.0),
    );
    final op = List.generate(
      ref.length + 1,
      (_) => List.filled(hyp.length + 1, 0),
    );
    for (var i = 1; i <= ref.length; i++) {
      d[i][0] = i.toDouble();
      op[i][0] = 1;
    }
    for (var j = 1; j <= hyp.length; j++) {
      d[0][j] = j.toDouble();
      op[0][j] = 2;
    }
    for (var i = 1; i <= ref.length; i++) {
      for (var j = 1; j <= hyp.length; j++) {
        final cost = ref[i - 1] == hyp[j - 1].text
            ? 0.0
            : .5 + phoneticDistance(ref[i - 1], hyp[j - 1].text);
        final choices = [
          d[i - 1][j - 1] + cost,
          d[i - 1][j] + 1,
          d[i][j - 1] + 1,
        ];
        final min = choices.reduce(math.min);
        d[i][j] = min;
        op[i][j] = choices.indexOf(min);
      }
    }
    var i = ref.length, j = hyp.length, correct = 0;
    final errors = <ReadingError>[];
    while (i > 0 || j > 0) {
      if (op[i][j] == 0) {
        final word = hyp[j - 1];
        if (ref[i - 1] == word.text) {
          correct++;
        } else {
          final distance = phoneticDistance(ref[i - 1], word.text);
          errors.add(
            ReadingError(
              i - 1,
              distance < .4
                  ? ReadingErrorKind.mispronunciation
                  : ReadingErrorKind.substitution,
              hypothesis: word.text,
              distance: distance,
              needsConfirmation:
                  word.confidence == null ||
                  word.confidence! < confidenceThreshold,
            ),
          );
        }
        if (j > 1 &&
            word.startMs - hyp[j - 2].endMs >
                (age == AgeBand.child ? 1000 : 700)) {
          errors.add(ReadingError(i - 1, ReadingErrorKind.hesitation));
        }
        i--;
        j--;
      } else if (op[i][j] == 1) {
        errors.add(ReadingError(i - 1, ReadingErrorKind.omission));
        i--;
      } else {
        final repeated =
            (i > 0 && ref[i - 1] == hyp[j - 1].text) ||
            (j > 1 && hyp[j - 2].text == hyp[j - 1].text) ||
            (j < hyp.length && hyp[j].text == hyp[j - 1].text);
        errors.add(
          ReadingError(
            math.max(0, i - 1),
            repeated ? ReadingErrorKind.repetition : ReadingErrorKind.insertion,
            hypothesis: hyp[j - 1].text,
          ),
        );
        j--;
      }
    }
    errors.sort((a, b) => a.referenceIndex.compareTo(b.referenceIndex));
    final ranked = [...errors]
      ..sort((a, b) {
        double priority(ReadingError e) =>
            (1 + (recurrence[ref[e.referenceIndex]] ?? 0)) *
            (e.kind == ReadingErrorKind.hesitation ? .3 : 1);
        final c = priority(b).compareTo(priority(a));
        return c == 0 ? a.referenceIndex.compareTo(b.referenceIndex) : c;
      });
    return ReadingScore(
      correct,
      correct * 60000 / durationMs,
      correct / ref.length,
      List.unmodifiable(errors),
      ranked.isEmpty ? null : ranked.first,
    );
  }
}
