import 'dart:math' as math;
import 'dart:typed_data';
import 'package:vaachak_engine/vaachak_engine.dart';

class AudioClip {
  final Float32List samples;
  final int sampleRate;
  AudioClip(this.samples, this.sampleRate) {
    if (sampleRate < 8000 ||
        sampleRate > 48000 ||
        samples.isEmpty ||
        samples.length > sampleRate * 60 ||
        samples.any((s) => !s.isFinite || s.abs() > 1)) {
      throw ArgumentError('Invalid audio clip');
    }
  }
  int get durationMs => (samples.length * 1000 / sampleRate).round();
  void clear() => samples.fillRange(0, samples.length, 0);
}

/// Bounded PCM16 little-endian capture; preserves split samples across chunks.
/// The owner must clear this buffer when capture stops or the app backgrounds.
class Pcm16CaptureBuffer {
  final int sampleRate;
  final Float32List _samples;
  int _length = 0;
  int? _lowByte;
  Pcm16CaptureBuffer({this.sampleRate = 16000, int maxSeconds = 60})
    : _samples = _allocate(sampleRate, maxSeconds);
  static Float32List _allocate(int sampleRate, int maxSeconds) {
    if (sampleRate < 8000 ||
        sampleRate > 48000 ||
        maxSeconds < 1 ||
        maxSeconds > 60) {
      throw ArgumentError('Invalid capture limits');
    }
    return Float32List(sampleRate * maxSeconds);
  }

  int get length => _length;
  bool get full => _length == _samples.length;
  void add(Uint8List chunk) {
    for (final byte in chunk) {
      if (full) break;
      if (_lowByte == null) {
        _lowByte = byte;
      } else {
        final unsigned = _lowByte! | (byte << 8);
        _samples[_length++] =
            (unsigned >= 32768 ? unsigned - 65536 : unsigned) / 32768;
        _lowByte = null;
      }
    }
  }

  AudioClip take() {
    if (_length == 0) {
      throw StateError('No speech was captured. Please try again.');
    }
    final clip = AudioClip(
      Float32List.fromList(_samples.sublist(0, _length)),
      sampleRate,
    );
    clear();
    return clip;
  }

  void clear() {
    _samples.fillRange(0, _samples.length, 0);
    _length = 0;
    _lowByte = null;
  }
}

class SignalQuality {
  final double rms, snrDb, clipping;
  final bool scorable;
  const SignalQuality(this.rms, this.snrDb, this.clipping, this.scorable);
  Map<String, dynamic> toJson() => {
    'rms': rms,
    'snrDb': snrDb,
    'clipping': clipping,
  };
  static SignalQuality measure(AudioClip clip) {
    final powers = <double>[];
    var sum = 0.0, clipped = 0;
    final frame = clip.sampleRate ~/ 50;
    for (var start = 0; start < clip.samples.length; start += frame) {
      var power = 0.0;
      final end = math.min(clip.samples.length, start + frame);
      for (var k = start; k < end; k++) {
        final s = clip.samples[k];
        power += s * s;
        if (s.abs() >= .99) {
          clipped++;
        }
      }
      sum += power;
      powers.add(power / (end - start));
    }
    powers.sort();
    final noise = math.max(1e-10, powers[(powers.length * .1).floor()]);
    final signal = math.max(1e-10, powers[(powers.length * .9).floor()]);
    final snr = 10 * math.log(signal / noise) / math.ln10,
        rms = math.sqrt(sum / clip.samples.length),
        ratio = clipped / clip.samples.length;
    return SignalQuality(
      rms,
      snr,
      ratio,
      rms >= .008 && snr >= 8 && ratio < .01 && clip.durationMs >= 300,
    );
  }
}

class Transcript {
  final List<SpokenWord> words;
  final String modelId;
  final bool hasWordTiming;
  const Transcript(this.words, this.modelId, {this.hasWordTiming = false});
}

abstract interface class SpeechService {
  Future<Transcript> recognise(AudioClip clip, {AgeBand age = AgeBand.student});
  Future<AudioClip> synthesise(String text);
  Future<void> dispose();
}
