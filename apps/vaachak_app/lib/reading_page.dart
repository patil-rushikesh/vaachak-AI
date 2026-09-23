import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_speech/vaachak_speech.dart';
import 'package:vaachak_speech/sherpa.dart';
import 'model_runtime.dart';
import 'pack_page.dart';
import 'session.dart';
import 'assessment_controller.dart';
import 'package:vaachak_content/vaachak_content.dart';

class ReadingPage extends StatefulWidget {
  final LearningSession session;
  final ReadingPassage? passage;
  final SkillAssessment? assessment;
  const ReadingPage({
    super.key,
    required this.session,
    this.passage,
    this.assessment,
  }) : assert(assessment == null || passage != null);
  @override
  State<ReadingPage> createState() => _ReadingPageState();
}

class _ReadingPageState extends State<ReadingPage> with WidgetsBindingObserver {
  ReadingPassage? get content {
    if (widget.passage != null) return widget.passage;
    for (final p in widget.session.bank.passages) {
      if (p.ages.contains(widget.session.profile.age) &&
          (p.approved ||
              const bool.fromEnvironment('ALLOW_DRAFT_CONTENT') &&
                  p.reviewStatus == 'draft')) {
        return p;
      }
    }
    return null;
  }

  String get passage => content?.text ?? '';
  late final assessmentController = AssessmentController(
    widget.session.store,
    widget.session.bank,
    widget.session.profile,
  );
  ReadingAssessmentEvidence? pendingEvidence;
  AudioClip? activeClip;
  int generation = 0;
  bool active = true;
  AudioRecorder? _recorder;
  AudioRecorder get recorder => _recorder ??= AudioRecorder();
  final capture = Pcm16CaptureBuffer();
  StreamSubscription<Uint8List>? subscription;
  Timer? timer;
  SherpaSpeechService? speech;
  ModelRuntime? runtime;
  int failures = 0;
  int recordingLimitSeconds = 60;
  bool recording = false, busy = false;
  String? message;
  ReadingScore? score;
  String? repeatWord;
  int repeats = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    generation++;
    active = false;
    activeClip?.clear();
    pendingEvidence = null;
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    subscription?.cancel();
    _recorder?.dispose();
    speech?.dispose();
    unawaited(
      ModelRuntime.channel.invokeMethod<void>('stopPcm').catchError((_) {}),
    );
    runtime?.packs.dispose();
    capture.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (!active) {
      capture.clear();
      activeClip?.clear();
      pendingEvidence = null;
      unawaited(speech?.dispose() ?? Future<void>.value());
      speech = null;
      unawaited(
        ModelRuntime.channel.invokeMethod<void>('stopPcm').catchError((_) {}),
      );
      generation++;
      if (recording) cancel();
    }
  }

  Future<void> cancel() async {
    generation++;
    await ModelRuntime.channel.invokeMethod<void>('stopPcm').catchError((_) {});
    timer?.cancel();
    try {
      await recorder.stop();
      await subscription?.cancel();
    } catch (_) {
      // Clearing the in-memory buffer must not depend on recorder shutdown.
    } finally {
      capture.clear();
      if (mounted) {
        setState(() {
          recording = false;
          message = 'Recording cancelled. No audio was saved.';
        });
      }
    }
  }

  Future<bool> consent(int ticket) async {
    final state = await widget.session.store.snapshot(
      widget.session.profile.id,
      widget.session.bank.graph,
    );
    if (!current(ticket)) return false;
    if (state.erased || state.consents['core'] != true) {
      throw StateError('Core learning consent is required');
    }
    if (state.consents['microphone'] == true) {
      return true;
    }
    if (!mounted) {
      return false;
    }
    final reference = await showDialog<String>(
      context: context,
      builder: (_) =>
          _MicrophoneConsentDialog(minor: widget.session.profile.minor),
    );
    final approved = reference != null;
    if (approved != true || !current(ticket)) {
      return false;
    }
    if (widget.session.profile.minor && reference!.length < 6) {
      throw StateError('Guardian microphone consent reference is required');
    }
    await widget.session.store.setConsent(
      widget.session.profile.id,
      'microphone',
      true,
      witnessReference: reference,
    );
    return true;
  }

  bool current(int ticket) =>
      mounted && active && widget.session.ready && ticket == generation;

  Future<void> appendMicrophoneEvent(
    int ticket,
    String type,
    Map<String, dynamic> payload,
  ) => widget.session.store.transaction(() async {
    if (!current(ticket)) throw StateError('Reading session has ended');
    final state = await widget.session.store.snapshot(
      widget.session.profile.id,
      widget.session.bank.graph,
    );
    if (state.erased ||
        state.consents['core'] != true ||
        state.consents['microphone'] != true) {
      throw StateError('Learning and microphone consent are required');
    }
    if (!current(ticket)) throw StateError('Reading session has ended');
    await widget.session.store.append(widget.session.profile.id, type, payload);
    if (!current(ticket)) throw StateError('Reading session has ended');
  });

  Future<bool> prepareSpeech(int ticket) async {
    if (!current(ticket)) return false;
    if (runtime == null) {
      final opened = await ModelRuntime.open();
      if (!current(ticket)) {
        await opened.packs.dispose();
        return false;
      }
      runtime = opened;
    }
    if (speech == null) {
      final opened = await runtime!.speech();
      if (!current(ticket)) {
        await opened.dispose();
        return false;
      }
      speech = opened;
    }
    return current(ticket);
  }

  Future<void> start() async {
    if (recording ||
        busy ||
        pendingEvidence != null ||
        !active ||
        !widget.session.ready) {
      return;
    }
    final ticket = generation;
    setState(() {
      busy = true;
      message = null;
      score = null;
    });
    try {
      if (content == null ||
          (!content!.approved &&
              (widget.assessment != null ||
                  !const bool.fromEnvironment('ALLOW_DRAFT_CONTENT')))) {
        throw StateError('Install a reviewed reading passage to continue.');
      }
      if (!await consent(ticket)) {
        return;
      }
      if (!current(ticket)) return;
      if (!await recorder.hasPermission()) {
        throw StateError(
          'Microphone permission is off. Use text practice, or enable the microphone in Settings.',
        );
      }
      if (!await prepareSpeech(ticket)) return;
      if (!current(ticket)) return;
      if (widget.assessment != null &&
          !content!.assessmentModelIds.contains(speech!.modelId)) {
        throw StateError(
          'Install a speech-model version approved for this reading check.',
        );
      }
      capture.clear();
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      if (!mounted || !active || ticket != generation) {
        await recorder.stop();
        return;
      }
      subscription = stream.listen(
        (chunk) {
          if (!current(ticket)) return;
          capture.add(chunk);
          if (capture.full) unawaited(stop());
        },
        onError: (Object error) {
          cancel();
        },
      );
      if (mounted) {
        setState(() => recording = true);
      }
      recordingLimitSeconds = speech!.maxRecordingSeconds;
      if (runtime!.packs.device.thermalLimited && recordingLimitSeconds > 30) {
        recordingLimitSeconds = 30;
      }
      timer = Timer(Duration(seconds: recordingLimitSeconds), stop);
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is StateError
              ? e.message.toString()
              : 'The microphone or model is unavailable. Try text practice.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> stop() async {
    if (!recording || busy) {
      return;
    }
    final ticket = generation;
    timer?.cancel();
    setState(() {
      recording = false;
      busy = true;
    });
    AudioClip? clip;
    try {
      await recorder.stop();
      await subscription?.cancel();
      if (!current(ticket)) return;
      if (capture.length == 0) {
        throw StateError('No speech was captured. Please try again.');
      }
      clip = capture.take();
      activeClip = clip;
      capture.clear();
      final quality = SignalQuality.measure(clip);
      if (!quality.scorable) {
        throw StateError(
          'Try a quieter place and speak a little closer to the microphone.',
        );
      }
      final transcript = await speech!.recognise(
        clip,
        age: widget.session.profile.age,
      );
      if (!current(ticket)) return;
      if (transcript.words.isEmpty) {
        throw StateError(
          'No speech was recognised. Please try again; no score was recorded.',
        );
      }
      if (widget.assessment != null) {
        pendingEvidence = assessmentController.evaluateReading(
          content!,
          clip,
          transcript,
        );
        await saveAssessment();
        return;
      }
      final target = repeatWord ?? passage,
          result = const ReadingAligner().score(
            target,
            transcript.words,
            clip.durationMs,
            age: widget.session.profile.age,
          );
      if (repeatWord == null) {
        await appendMicrophoneEvent(ticket, 'ReadingAttemptScored', {
          'passageId': content!.id,
          'passageVersion': content!.version,
          'durationMs': clip.durationMs,
          'wcpm': result.wcpm,
          'accuracy': result.accuracy,
          'signalQuality': quality.toJson(),
          'modelId': transcript.modelId,
          'errors': result.errors.map((e) => e.toJson()).toList(),
        });
      } else {
        repeats++;
        await appendMicrophoneEvent(ticket, 'WordRepeated', {
          'word': repeatWord,
          'score': result.accuracy,
        });
      }
      if (current(ticket)) {
        setState(() {
          score = result;
          message = result.correction == null
              ? 'Nicely read. Keep building your confidence.'
              : result.correction!.needsConfirmation
              ? 'Did you say “${result.correction!.hypothesis}”? Recognition may be uncertain; practise the reference word once more.'
              : 'Let’s practise “${normaliseWords(target)[result.correction!.referenceIndex]}” once more.';
          if (repeatWord != null && (result.accuracy >= .8 || repeats >= 3)) {
            repeatWord = null;
            repeats = 0;
            message = 'Good practice. You can move on whenever you’re ready.';
          }
        });
      }
    } catch (e) {
      if (!current(ticket)) return;
      if (widget.assessment != null) {
        setState(
          () => message = pendingEvidence != null
              ? 'The result could not be saved. Retry saving; your recording has been cleared.'
              : e is StateError
              ? e.message.toString()
              : 'This recording could not be scored. Try again; no assessment answer was saved.',
        );
        return;
      }
      failures++;
      try {
        await appendMicrophoneEvent(ticket, 'ReadingAttemptUnscored', {
          'reason': 'signalOrModelUnavailable',
        });
      } catch (_) {
        /* The UI reports the unsaved attempt below. */
      }
      if (mounted) {
        setState(
          () => message = failures >= 2
              ? 'Let’s switch to text practice for now. No reading score was recorded.'
              : e is StateError
              ? e.message.toString()
              : 'This attempt could not be scored or saved. Try again.',
        );
      }
    } finally {
      clip?.clear();
      activeClip = null;
      capture.clear();
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> saveAssessment() async {
    final evidence = pendingEvidence;
    if (evidence == null || !mounted || !active) return;
    await assessmentController.answerReading(widget.assessment!, evidence);
    await widget.session.reloadProgress();
    pendingEvidence = null;
    if (mounted && active && widget.session.ready) Navigator.pop(context, true);
  }

  Future<void> retryAssessmentSave() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await saveAssessment();
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'The result could not be saved. Check storage and consent, then retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> listen() async {
    if (busy || recording || widget.assessment != null || content == null) {
      return;
    }
    final ticket = generation;
    setState(() => busy = true);
    AudioClip? audio;
    Uint8List? bytes;
    try {
      if (!await prepareSpeech(ticket)) return;
      audio = await speech!.synthesise(repeatWord ?? passage);
      if (!current(ticket)) return;
      bytes = Uint8List(audio.samples.length * 2);
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < audio.samples.length; i++) {
        data.setInt16(
          i * 2,
          (audio.samples[i] * 32767).round().clamp(-32768, 32767),
          Endian.little,
        );
      }
      await ModelRuntime.channel.invokeMethod<void>('playPcm', {
        'samples': bytes,
        'sampleRate': audio.sampleRate,
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'The offline voice is unavailable. Read the text, or install a verified speech pack.',
        );
      }
    } finally {
      audio?.clear();
      bytes?.fillRange(0, bytes.length, 0);
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => content == null
      ? Scaffold(
          appBar: AppBar(title: const Text('Reading')),
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Install reviewed reading passages to use the reading coach.',
              ),
            ),
          ),
        )
      : Scaffold(
          appBar: AppBar(title: const Text('Read with confidence')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    widget.assessment == null
                        ? 'READING COACH'
                        : 'READING CHECK',
                  ),
                  const SizedBox(height: 16),
                  Text(
                    repeatWord == null ? content!.title : 'One word at a time',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        repeatWord ?? passage,
                        style: Theme.of(
                          context,
                        ).textTheme.headlineSmall?.copyWith(height: 1.7),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (widget.assessment == null)
                        OutlinedButton.icon(
                          onPressed: busy || recording ? null : listen,
                          icon: const Icon(Icons.volume_up_outlined),
                          label: const Text('Listen'),
                        ),
                      FilledButton.icon(
                        onPressed: busy || pendingEvidence != null
                            ? null
                            : recording
                            ? stop
                            : failures >= 2
                            ? null
                            : start,
                        icon: Icon(recording ? Icons.stop : Icons.mic_none),
                        label: Text(
                          recording ? 'Stop and check' : 'Read aloud',
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const PackPage()),
                        ),
                        child: const Text('Offline packs'),
                      ),
                    ],
                  ),
                  if (pendingEvidence != null)
                    OutlinedButton(
                      onPressed: busy ? null : retryAssessmentSave,
                      child: const Text('Retry saving result'),
                    ),
                  if (widget.assessment != null)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Read the passage once. Leaving before a result is saved keeps this passage unanswered. Audio is cleared after every attempt.',
                      ),
                    ),
                  if (recording)
                    Padding(
                      padding: EdgeInsets.only(top: 20),
                      child: Text(
                        'Listening… tap Stop when you finish. Maximum $recordingLimitSeconds seconds.',
                      ),
                    ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 20),
                      child: LinearProgressIndicator(),
                    ),
                  if (message != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(message!),
                      ),
                    ),
                  if (score != null) ...[
                    Text(
                      '${score!.wcpm.round()} words correct per minute · ${(score!.accuracy * 100).round()}% word accuracy',
                    ),
                    if (score!.correction != null && repeatWord == null)
                      TextButton(
                        onPressed: () => setState(() {
                          repeatWord = normaliseWords(
                            passage,
                          )[score!.correction!.referenceIndex];
                          score = null;
                          repeats = 0;
                        }),
                        child: const Text('Practise this word'),
                      ),
                  ],
                  const SizedBox(height: 24),
                  const Text(
                    'Your voice stays on this device and is cleared after each attempt.',
                  ),
                  if (failures >= 2)
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Back to text practice'),
                    ),
                ],
              ),
            ),
          ),
        );
}

class _MicrophoneConsentDialog extends StatefulWidget {
  final bool minor;
  const _MicrophoneConsentDialog({required this.minor});
  @override
  State<_MicrophoneConsentDialog> createState() =>
      _MicrophoneConsentDialogState();
}

class _MicrophoneConsentDialogState extends State<_MicrophoneConsentDialog> {
  final witness = TextEditingController();
  @override
  void dispose() {
    witness.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Use the microphone?'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Speech is processed on this phone. Audio stays in memory and is cleared after scoring. No recording is uploaded.',
          ),
          if (widget.minor) ...[
            const SizedBox(height: 16),
            const Text(
              'A teacher must verify guardian consent for microphone use.',
            ),
            TextField(
              controller: witness,
              decoration: const InputDecoration(
                labelText: 'Witnessed microphone consent reference',
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Not now'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, witness.text.trim()),
        child: const Text('Allow'),
      ),
    ],
  );
}
