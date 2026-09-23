import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:vaachak_speech/vaachak_speech.dart';

void main() {
  test('silence clipping and steady noise are unscored', () {
    expect(
      SignalQuality.measure(AudioClip(Float32List(16000), 16000)).scorable,
      isFalse,
    );
    expect(
      SignalQuality.measure(
        AudioClip(Float32List.fromList(List.filled(16000, 1)), 16000),
      ).scorable,
      isFalse,
    );
    expect(
      SignalQuality.measure(
        AudioClip(Float32List.fromList(List.filled(16000, .2)), 16000),
      ).scorable,
      isFalse,
    );
  });
  test('speech-shaped input passes and can be zeroed', () {
    final clip = AudioClip(
      Float32List.fromList(
        List.generate(16000, (i) => sin(i * .1) * (i < 4000 ? .001 : .2)),
      ),
      16000,
    );
    expect(SignalQuality.measure(clip).scorable, isTrue);
    clip.clear();
    expect(clip.samples.every((s) => s == 0), isTrue);
  });
  test('invalid and oversized buffers rejected', () {
    expect(
      () => AudioClip(Float32List.fromList([double.nan]), 16000),
      throwsArgumentError,
    );
    expect(
      () => AudioClip(Float32List(16000 * 61), 16000),
      throwsArgumentError,
    );
  });
}
