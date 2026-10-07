import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'class_setup_dialog.dart';
import 'lesson_recordings.dart';
import 'recording_file_native.dart'
    if (dart.library.js_interop) 'recording_file_web.dart';

/// Teacher records a lesson clip and assigns it to the class or one learner.
class TeacherRecordingPage extends StatefulWidget {
  final LessonRecordingService service;
  final String teacherId, classId, className, defaultLanguage;
  final List<Map<String, dynamic>> learners;
  const TeacherRecordingPage({
    super.key,
    required this.service,
    required this.teacherId,
    required this.classId,
    required this.className,
    required this.learners,
    this.defaultLanguage = 'en',
  });
  @override
  State<TeacherRecordingPage> createState() => _TeacherRecordingState();
}

class _TeacherRecordingState extends State<TeacherRecordingPage> {
  final recorder = AudioRecorder();
  final player = AudioPlayer();
  final title = TextEditingController(), instructions = TextEditingController();
  Timer? ticker;
  final clock = Stopwatch();
  bool recording = false, busy = false, playing = false;
  String? path, message;
  int durationMs = 0;
  String? learnerId; // null = whole class
  int dueDays = 0;
  late String language = classLanguages.containsKey(widget.defaultLanguage)
      ? widget.defaultLanguage
      : 'en';

  // Browsers record Opus/WebM; Android and iOS record AAC in MP4.
  String get extension => kIsWeb ? 'webm' : 'm4a';
  String get mime => kIsWeb ? 'audio/webm' : 'audio/mp4';
  bool get hasRecording => path != null && !recording && durationMs >= 1000;

  @override
  void dispose() {
    ticker?.cancel();
    final pending = path;
    if (pending != null) unawaited(deleteRecording(pending));
    unawaited(recorder.dispose());
    unawaited(player.dispose());
    title.dispose();
    instructions.dispose();
    super.dispose();
  }

  Future<void> start() async {
    setState(() => message = null);
    try {
      if (!await recorder.hasPermission()) {
        setState(
          () => message =
              'Microphone permission is needed to record. Allow it in settings.',
        );
        return;
      }
      final old = path;
      if (old != null) await deleteRecording(old);
      final target = await newRecordingPath(extension);
      await recorder.start(
        RecordConfig(
          encoder: kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: target,
      );
      clock
        ..reset()
        ..start();
      ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (clock.elapsed.inSeconds >= maxRecordingSeconds) {
          unawaited(stop());
        } else if (mounted) {
          setState(() {});
        }
      });
      setState(() {
        recording = true;
        path = target;
        durationMs = 0;
      });
    } catch (_) {
      setState(() => message = 'Recording could not start. Please try again.');
    }
  }

  Future<void> stop() async {
    ticker?.cancel();
    clock.stop();
    try {
      final output = await recorder.stop();
      if (mounted) {
        setState(() {
          recording = false;
          path = output ?? path;
          durationMs = clock.elapsedMilliseconds;
          if (durationMs < 1000) {
            message = 'Recording is too short. Record at least one second.';
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          recording = false;
          message = 'Recording could not be saved. Please try again.';
        });
      }
    }
  }

  Future<void> togglePlayback() async {
    final file = path;
    if (file == null) return;
    if (playing) {
      await player.stop();
      if (mounted) setState(() => playing = false);
      return;
    }
    try {
      final bytes = await readRecording(file);
      player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => playing = false);
      });
      await player.play(BytesSource(bytes, mimeType: mime));
      if (mounted) setState(() => playing = true);
    } catch (_) {
      if (mounted) setState(() => message = 'Playback is unavailable.');
    }
  }

  Future<void> send() async {
    final file = path;
    final name = title.text.trim();
    if (file == null || !hasRecording) return;
    if (name.isEmpty) {
      setState(() => message = 'Give the recording a title.');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final bytes = await readRecording(file);
      await widget.service.uploadAndAssign(
        teacherId: widget.teacherId,
        bytes: bytes,
        title: name,
        language: language,
        durationMs: durationMs,
        mime: mime,
        extension: extension,
        classId: widget.classId,
        learnerId: learnerId,
        instructions: instructions.text.trim().isEmpty
            ? null
            : instructions.text.trim(),
        due: dueDays == 0 ? null : DateTime.now().add(Duration(days: dueDays)),
      );
      await deleteRecording(file);
      path = null;
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'The recording was not assigned. Check your connection and class assignment, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _clock(int ms) {
    final s = ms ~/ 1000;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = recording ? clock.elapsedMilliseconds : durationMs;
    return Scaffold(
      appBar: AppBar(title: Text('Record lesson · ${widget.className}')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            _clock(elapsed),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayMedium,
          ),
          const SizedBox(height: 8),
          Text(
            recording
                ? 'Recording… (up to ${maxRecordingSeconds ~/ 60} minutes)'
                : hasRecording
                ? 'Ready to send'
                : 'Tap record to start',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : (recording ? stop : start),
                icon: Icon(recording ? Icons.stop : Icons.mic),
                label: Text(
                  recording
                      ? 'Stop'
                      : hasRecording
                      ? 'Record again'
                      : 'Record',
                ),
              ),
              if (hasRecording) ...[
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: busy ? null : togglePlayback,
                  icon: Icon(playing ? Icons.stop : Icons.play_arrow),
                  label: Text(playing ? 'Stop' : 'Play back'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 24),
          TextField(
            controller: title,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: instructions,
            maxLength: 500,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Instructions for learners (optional)',
            ),
          ),
          DropdownButtonFormField<String>(
            initialValue: language,
            decoration: const InputDecoration(labelText: 'Language spoken'),
            items: [
              for (final e in classLanguages.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => language = v ?? language),
          ),
          DropdownButtonFormField<String?>(
            initialValue: learnerId,
            decoration: const InputDecoration(labelText: 'Assign to'),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Whole class'),
              ),
              for (final l in widget.learners)
                DropdownMenuItem<String?>(
                  value: l['id'] as String,
                  child: Text(l['display_name'] as String),
                ),
            ],
            onChanged: (v) => setState(() => learnerId = v),
          ),
          DropdownButtonFormField<int>(
            initialValue: dueDays,
            decoration: const InputDecoration(labelText: 'Due'),
            items: const [
              DropdownMenuItem(value: 0, child: Text('No due date')),
              DropdownMenuItem(value: 1, child: Text('Tomorrow')),
              DropdownMenuItem(value: 3, child: Text('In 3 days')),
              DropdownMenuItem(value: 7, child: Text('In a week')),
            ],
            onChanged: (v) => setState(() => dueDays = v ?? 0),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy || !hasRecording ? null : send,
            child: Text(busy ? 'Sending…' : 'Send to learners'),
          ),
          if (busy) const LinearProgressIndicator(),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(
                liveRegion: true,
                child: Text(message!, style: const TextStyle(color: Colors.red)),
              ),
            ),
        ],
      ),
    );
  }
}
