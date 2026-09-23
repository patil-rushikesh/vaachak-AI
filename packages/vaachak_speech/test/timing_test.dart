import 'package:test/test.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_speech/timing.dart';

void main() {
  Map<String, dynamic> fixture() => {
    'text': 'We read books.',
    'tokens': [' We', ' re', 'ad', ' books', '.'],
    'timestamps': [0.0, .3, .4, 1.8, 2.1],
    'durations': [.2, .1, .2, .3, .0],
  };
  test('merges actual subword intervals and enables hesitation alignment', () {
    final transcript = transcriptFromNative(fixture(), 'fixture', 3000);
    expect(transcript.hasWordTiming, isTrue);
    expect(transcript.words.map((w) => w.text), ['we', 'read', 'books']);
    expect(transcript.words.map((w) => (w.startMs, w.endMs)), [
      (0, 200),
      (300, 600),
      (1800, 2100),
    ]);
    expect(transcript.words.every((w) => w.confidence == null), isTrue);
    final score = const ReadingAligner().score(
      'We read books',
      transcript.words,
      3000,
    );
    expect(score.correct, 3);
    expect(score.errors.single.kind, ReadingErrorKind.hesitation);
  });
  test('missing durations never invents word end times', () {
    final result = fixture()..remove('durations');
    final transcript = transcriptFromNative(result, 'fixture', 3000);
    expect(transcript.hasWordTiming, isFalse);
    expect(
      transcript.words.every((w) => w.startMs == 0 && w.endMs == 0),
      isTrue,
    );
  });
  test(
    'rejects mismatched arrays and out-of-bounds or nonfinite intervals',
    () {
      for (final patch in [
        {
          'durations': [.2],
        },
        {
          'timestamps': [0.0, double.nan, .4, 1.8, 2.1],
        },
        {
          'durations': [.2, .1, .2, 2.0, .0],
        },
        {
          'timestamps': [0.0, .1, .4, 1.8, 2.1],
        },
        {
          'durations': [.2, .1, -.2, .3, .0],
        },
        {
          'durations': [.2, .1, .0, .3, .0],
        },
      ]) {
        expect(
          transcriptFromNative(
            fixture()..addAll(patch),
            'fixture',
            3000,
          ).hasWordTiming,
          isFalse,
        );
      }
    },
  );
  test('rejects tokens inconsistent with decoded text', () {
    final result = fixture()..['text'] = 'We read stories.';
    final transcript = transcriptFromNative(result, 'fixture', 3000);
    expect(transcript.hasWordTiming, isFalse);
    expect(transcript.words.last.text, 'stories');
  });
  test('ambiguous multiword tokens and expanded contractions stay untimed', () {
    for (final phrase in ['we read', "can't", 'twenty-one']) {
      expect(
        transcriptFromNative(
          {
            'text': phrase,
            'tokens': [phrase],
            'timestamps': [0.0],
            'durations': [.3],
          },
          'fixture',
          1000,
        ).hasWordTiming,
        isFalse,
      );
    }
  });
  test(
    'unsupported boundary markers and character tokenization stay untimed',
    () {
      final result = fixture()
        ..['tokens'] = ['▁We', '▁re', 'ad', '▁books', '.'];
      expect(
        transcriptFromNative(result, 'fixture', 3000).hasWordTiming,
        isFalse,
      );
    },
  );
  test('separate whitespace and punctuation preserve measured gaps', () {
    final result = {
      'text': 'Hi, Sam!',
      'tokens': ['Hi', ',', ' ', 'Sam', '!'],
      'timestamps': [0.0, .2, .3, 1.2, 1.5],
      'durations': [.2, .1, .2, .3, .0],
    };
    final transcript = transcriptFromNative(result, 'fixture', 2000);
    expect(transcript.hasWordTiming, isTrue);
    expect(transcript.words.map((w) => (w.startMs, w.endMs)), [
      (0, 200),
      (1200, 1500),
    ]);
  });
}
