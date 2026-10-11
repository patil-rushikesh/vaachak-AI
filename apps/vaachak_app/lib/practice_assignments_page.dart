import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'lesson_recordings.dart';

/// Learner view: recordings the teacher has assigned to this learner or class.
class PracticeAssignmentsPage extends StatefulWidget {
  final LessonRecordingService service;
  const PracticeAssignmentsPage({super.key, required this.service});
  @override
  State<PracticeAssignmentsPage> createState() => _PracticeAssignmentsState();
}

class _PracticeAssignmentsState extends State<PracticeAssignmentsPage> {
  final player = AudioPlayer();
  late Future<List<PracticeAssignment>> assignments;
  String? playingId, loadingId, message;
  StreamSubscription<void>? done;

  @override
  void initState() {
    super.initState();
    assignments = widget.service.myAssignments();
    done = player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => playingId = null);
    });
  }

  @override
  void dispose() {
    unawaited(done?.cancel());
    unawaited(player.dispose());
    super.dispose();
  }

  void reload() => setState(() {
    message = null;
    assignments = widget.service.myAssignments();
  });

  Future<void> toggle(PracticeAssignment a) async {
    if (playingId == a.id) {
      await player.stop();
      if (mounted) setState(() => playingId = null);
      return;
    }
    setState(() {
      loadingId = a.id;
      message = null;
    });
    try {
      final bytes = await widget.service.download(a);
      await player.stop();
      await player.play(BytesSource(bytes, mimeType: a.recording.mime));
      if (mounted) setState(() => playingId = a.id);
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'This recording could not be played. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => loadingId = null);
    }
  }

  String _due(DateTime d) =>
      'Due ${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Practice from your teacher'),
        actions: [
          IconButton(
            onPressed: reload,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<PracticeAssignment>>(
        future: assignments,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Practice could not be loaded. Join a class, wait for your teacher to approve you, then check your connection.',
              ),
            );
          }
          final items = snapshot.data!;
          if (items.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No practice assigned yet. Check back later.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Semantics(liveRegion: true, child: Text(message!)),
                ),
              for (final a in items)
                Card(
                  child: ListTile(
                    title: Text(a.title),
                    subtitle: Text(
                      [
                        a.className,
                        '${(a.recording.durationMs / 1000).round()} s',
                        if (a.dueAt != null) _due(a.dueAt!),
                        if (a.scope == 'learner') 'Just for you',
                        if (a.instructions != null) a.instructions!,
                      ].join(' · '),
                    ),
                    trailing: loadingId == a.id
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            tooltip: playingId == a.id ? 'Stop' : 'Play',
                            onPressed: () => toggle(a),
                            icon: Icon(
                              playingId == a.id
                                  ? Icons.stop_circle_outlined
                                  : Icons.play_circle_outline,
                              size: 36,
                            ),
                          ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
