import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:vaachak_speech/vaachak_speech.dart';
import 'package:vaachak_speech/sherpa.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

void main() {
  test('PCM16 preserves signed samples across arbitrary odd chunks', () {
    final buffer = Pcm16CaptureBuffer();
    buffer.add(Uint8List.fromList([0]));
    buffer.add(Uint8List.fromList([128, 255, 127, 0]));
    buffer.add(Uint8List.fromList([0, 0, 64]));
    expect(buffer.length, 4);
    final clip = buffer.take();
    expect(clip.samples, [-1, 32767 / 32768, 0, .5]);
    expect(buffer.length, 0);
    clip.clear();
    expect(clip.samples, everyElement(0));
  });
  test('capture caps duration and ignores surplus bytes', () {
    final buffer = Pcm16CaptureBuffer(sampleRate: 8000, maxSeconds: 1);
    buffer.add(Uint8List(20000));
    expect(buffer.full, isTrue);
    expect(buffer.take().durationMs, 1000);
    expect(buffer.full, isFalse);
  });
  test('clear discards partial samples as well as full samples', () {
    final buffer = Pcm16CaptureBuffer();
    buffer.add(Uint8List.fromList([255, 127, 255]));
    buffer.clear();
    expect(buffer.take, throwsStateError);
    buffer.add(Uint8List.fromList([0, 128]));
    expect(buffer.take().samples, [-1]);
  });
  test('capture validates limits', () {
    expect(() => Pcm16CaptureBuffer(maxSeconds: 61), throwsArgumentError);
    expect(() => Pcm16CaptureBuffer(sampleRate: 7999), throwsArgumentError);
  });
  test(
    'disposed speech service fails closed without opening native models',
    () async {
      var releases = 0;
      final service = SherpaSpeechService(
        recognizerConfig: const sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(tokens: ''),
        ),
        ttsConfig: const sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(),
        ),
        modelId: 'test',
        onDispose: () => releases++,
      );
      await service.dispose();
      await service.dispose();
      expect(releases, 1);
      await expectLater(service.synthesise('Hello'), throwsStateError);
    },
  );
  test(
    'invalid TTS requests fail before allocating native resources',
    () async {
      final service = SherpaSpeechService(
        recognizerConfig: const sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(tokens: ''),
        ),
        ttsConfig: const sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(),
        ),
        modelId: 'test',
      );
      await expectLater(service.synthesise(' '), throwsArgumentError);
      await expectLater(service.synthesise('a' * 501), throwsArgumentError);
      await service.dispose();
    },
  );
  test(
    'missing native runtime returns a recoverable failure promptly',
    () async {
      final service = SherpaSpeechService(
        recognizerConfig: const sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(tokens: ''),
        ),
        ttsConfig: const sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(),
        ),
        modelId: 'test',
        libraryPath: '/nonexistent-vaachak-test-library',
      );
      addTearDown(service.dispose);
      await expectLater(
        service.synthesise('Hello').timeout(const Duration(seconds: 5)),
        throwsStateError,
      );
    },
  );
  test(
    'Whisper rejects audio above its native window before inference',
    () async {
      final service = SherpaSpeechService(
        recognizerConfig: const sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            tokens: '',
            whisper: sherpa.OfflineWhisperModelConfig(
              encoder: 'fixture',
              decoder: 'fixture',
            ),
          ),
        ),
        ttsConfig: const sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(),
        ),
        modelId: 'fixture',
      );
      expect(service.maxRecordingSeconds, 29);
      final clip = AudioClip(Float32List(16000 * 30), 16000);
      await expectLater(service.recognise(clip), throwsStateError);
      clip.clear();
      await service.dispose();
    },
  );
}
