import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'timing.dart';
import 'dart:isolate';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:vaachak_engine/vaachak_engine.dart';
import 'vaachak_speech.dart';

class SherpaSpeechService implements SpeechService {
  final sherpa.OfflineRecognizerConfig recognizerConfig;
  final sherpa.OfflineTtsConfig ttsConfig;
  final String modelId;
  final void Function()? onDispose;

  /// Optional explicit native library path for desktop integration tests.
  final String? libraryPath;
  bool _disposeNotified = false;
  Isolate? _worker;
  SendPort? _port;
  Timer? _idle;
  Completer<void>? _cancelled;
  Future<void>? _starting, _disposing;
  Completer<void>? _workerDone;
  bool _busy = false, _disposed = false;
  SherpaSpeechService({
    required this.recognizerConfig,
    required this.ttsConfig,
    required this.modelId,
    this.onDispose,
    this.libraryPath,
  });
  Future<void> _start() async {
    if (_port != null) return;
    if (_starting != null) return _starting!;
    final start = _spawn();
    _starting = start;
    try {
      await start;
    } finally {
      _starting = null;
    }
  }

  Future<void> _spawn() async {
    // A previous idle worker may still be freeing native allocations.
    await _release();
    if (_disposed) throw StateError('Speech service was disposed');
    final ready = ReceivePort();
    final exited = ReceivePort();
    final done = _workerDone = Completer<void>();
    exited.listen((_) {
      if (!done.isCompleted) done.complete();
      exited.close();
    });
    try {
      _worker = await Isolate.spawn(_run, [
        ready.sendPort,
        recognizerConfig,
        ttsConfig,
        libraryPath,
      ], onExit: exited.sendPort);
      final handshake = await ready.first.timeout(const Duration(seconds: 15));
      if (handshake is! SendPort) {
        throw StateError('Speech native runtime is unavailable');
      }
      _port = handshake;
      if (_disposed) {
        await _release();
        throw StateError('Speech service was disposed');
      }
    } catch (_) {
      // No inference request has been sent at this point. If startup failed
      // before the handshake, there are no recognizer/TTS allocations to free.
      if (_port == null) _worker?.kill(priority: Isolate.immediate);
      if (_worker == null && !done.isCompleted) done.complete();
      await _release();
      rethrow;
    } finally {
      ready.close();
      if (done.isCompleted) exited.close();
    }
  }

  Future<dynamic> _request(String operation, dynamic data) async {
    if (_disposed || _busy) {
      throw StateError('Speech service is unavailable or busy');
    }
    _busy = true;
    final cancelled = _cancelled = Completer<void>();
    _idle?.cancel();
    final reply = ReceivePort();
    try {
      await _start();
      _port!.send([operation, data, reply.sendPort]);
      final result =
          await Future.any<dynamic>([
                reply.first,
                cancelled.future.then<dynamic>(
                  (_) => throw StateError('Speech cancelled'),
                ),
              ]).timeout(const Duration(seconds: 90))
              as Map;
      if (result['error'] != null) {
        throw StateError(result['error'] as String);
      }
      return result['result'];
    } on TimeoutException {
      unawaited(dispose());
      rethrow;
    } finally {
      _cancelled = null;
      reply.close();
      _busy = false;
      if (!_disposed) {
        _idle = Timer(const Duration(seconds: 90), () => unawaited(_release()));
      }
    }
  }

  int get maxRecordingSeconds =>
      recognizerConfig.model.whisper.encoder.isNotEmpty ? 29 : 60;

  @override
  Future<Transcript> recognise(
    AudioClip clip, {
    AgeBand age = AgeBand.student,
  }) async {
    if (clip.durationMs > maxRecordingSeconds * 1000) {
      throw StateError(
        'This speech model supports recordings up to $maxRecordingSeconds seconds. Please try a shorter recording.',
      );
    }
    if (!SignalQuality.measure(clip).scorable) {
      throw StateError(
        'Please try once more in a quieter place, closer to the microphone.',
      );
    }
    final data =
        await _request('asr', [
              TransferableTypedData.fromList([
                clip.samples.buffer.asUint8List(
                  clip.samples.offsetInBytes,
                  clip.samples.lengthInBytes,
                ),
              ]),
              clip.sampleRate,
            ])
            as Map;
    final text = data['text'] as String;
    if (normaliseWords(text).isEmpty) {
      throw StateError(
        'No speech was recognised. Please try again; no score was recorded.',
      );
    }
    return transcriptFromNative(data, modelId, clip.durationMs);
  }

  @override
  Future<AudioClip> synthesise(String text) async {
    if (text.trim().isEmpty || text.length > 500) {
      throw ArgumentError('TTS text must contain 1–500 characters');
    }
    final result = await _request('tts', text) as List;
    final samples = (result[0] as TransferableTypedData)
        .materialize()
        .asFloat32List();
    try {
      return AudioClip(samples, result[1] as int);
    } catch (_) {
      samples.fillRange(0, samples.length, 0);
      rethrow;
    }
  }

  Future<void> _release() async {
    _idle?.cancel();
    final worker = _worker;
    final done = _workerDone;
    final port = _port;
    _port = null;
    // Native decoding is synchronous. Queue cleanup instead of killing an
    // isolate that owns FFI resources. The lease remains held until worker exit.
    port?.send(['dispose']);
    if (done != null) await done.future;
    if (identical(_worker, worker)) {
      _worker = null;
      _workerDone = null;
    }
  }

  @override
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    if (_cancelled?.isCompleted == false) _cancelled!.complete();
    try {
      await _starting;
    } catch (_) {
      /* Startup owns its cleanup. */
    }
    await _release();
    if (!_disposeNotified) {
      _disposeNotified = true;
      onDispose?.call();
    }
  }

  static void _run(List<dynamic> init) {
    late final _NativeResults nativeResults;
    try {
      sherpa.initBindings(init[3] as String?);
      nativeResults = _NativeResults(init[3] as String?);
    } catch (_) {
      (init[0] as SendPort).send('nativeRuntimeUnavailable');
      return;
    }
    final port = ReceivePort();
    (init[0] as SendPort).send(port.sendPort);
    sherpa.OfflineRecognizer? recognizer;
    sherpa.OfflineTts? tts;
    port.listen((dynamic message) {
      final m = message as List;
      if (m[0] == 'dispose') {
        recognizer?.free();
        tts?.free();
        port.close();
        Isolate.exit();
      }
      final reply = m[2] as SendPort;
      try {
        if (m[0] == 'asr') {
          tts?.free();
          tts = null;
          final data = m[1] as List,
              samples = (data[0] as TransferableTypedData)
                  .materialize()
                  .asFloat32List();
          sherpa.OfflineStream? stream;
          try {
            recognizer ??= sherpa.OfflineRecognizer(
              init[1] as sherpa.OfflineRecognizerConfig,
            );
            stream = recognizer!.createStream();
            stream.acceptWaveform(samples: samples, sampleRate: data[1] as int);
            recognizer!.decode(stream);
            reply.send({'result': nativeResults.read(stream)});
          } finally {
            samples.fillRange(0, samples.length, 0);
            stream?.free();
          }
        } else {
          recognizer?.free();
          recognizer = null;
          tts ??= sherpa.OfflineTts(init[2] as sherpa.OfflineTtsConfig);
          final audio = tts!.generate(text: m[1] as String, sid: 0, speed: 1);
          try {
            reply.send({
              'result': [
                TransferableTypedData.fromList([
                  audio.samples.buffer.asUint8List(
                    audio.samples.offsetInBytes,
                    audio.samples.lengthInBytes,
                  ),
                ]),
                audio.sampleRate,
              ],
            });
          } finally {
            audio.samples.fillRange(0, audio.samples.length, 0);
          }
        }
      } catch (_) {
        reply.send({
          'error':
              'The speech model could not run. Use text practice or reinstall the verified pack.',
        });
      }
    });
  }
}

// sherpa_onnx 1.13.8's Dart result wrapper omits native `durations`.
// Use its documented C JSON API, copying the string and freeing it immediately.
// https://k2-fsa.github.io/sherpa/onnx/c-api/index.html
class _NativeResults {
  late final Pointer<Utf8> Function(Pointer<Void>) getJson;
  late final void Function(Pointer<Utf8>) freeJson;
  _NativeResults(String? path) {
    final resolved = path ?? sherpa.resolveSherpaOnnxPathSync();
    // The public Sherpa initializer takes a platform-package directory, not a
    // library filename. Match its pinned loader so both APIs use the same binary.
    final DynamicLibrary library;
    if (Platform.isMacOS) {
      library = resolved == null
          ? DynamicLibrary.process()
          : DynamicLibrary.open(
              '$resolved/sherpa_onnx_macos/sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx-c-api.dylib',
            );
    } else if (Platform.isIOS) {
      library = DynamicLibrary.process();
    } else if (Platform.isAndroid || Platform.isLinux) {
      library = DynamicLibrary.open(
        resolved == null
            ? 'libsherpa-onnx-c-api.so'
            : '$resolved/libsherpa-onnx-c-api.so',
      );
    } else if (Platform.isWindows) {
      library = DynamicLibrary.open(
        resolved == null
            ? 'sherpa-onnx-c-api.dll'
            : '$resolved/sherpa-onnx-c-api.dll',
      );
    } else {
      throw UnsupportedError('Unsupported native speech platform');
    }
    getJson = library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('SherpaOnnxGetOfflineStreamResultAsJson');
    freeJson = library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('SherpaOnnxDestroyOfflineStreamResultJson');
  }
  Map<String, dynamic> read(sherpa.OfflineStream stream) {
    final json = getJson(stream.ptr.cast<Void>());
    if (json == nullptr) {
      throw StateError('Native speech result is unavailable');
    }
    try {
      return jsonDecode(json.toDartString()) as Map<String, dynamic>;
    } finally {
      freeJson(json);
    }
  }
}
