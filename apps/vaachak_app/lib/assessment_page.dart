import 'package:flutter/material.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'assessment_controller.dart';
import 'session.dart';
import 'reading_page.dart';

class AssessmentPage extends StatefulWidget {
  final LearningSession session;
  const AssessmentPage({super.key, required this.session});
  @override
  State<AssessmentPage> createState() => _AssessmentPageState();
}

class _AssessmentPageState extends State<AssessmentPage> {
  late final controller = AssessmentController(
    widget.session.store,
    widget.session.bank,
    widget.session.profile,
  );
  Map<Skill, SkillAssessment> runs = {};
  Skill? selected;
  bool busy = true;
  String? error;
  Future<void> Function()? retry;
  @override
  void initState() {
    super.initState();
    perform(refresh);
  }

  Future<void> refresh() async {
    final loaded = await controller.load();
    await widget.session.reloadProgress();
    if (mounted) setState(() => runs = loaded);
  }

  Future<void> perform(Future<void> Function() operation) async {
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
        retry = null;
      });
    }
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        setState(() {
          error =
              'The check could not be updated. Your saved answers remain on this device. Check storage and retry.';
          retry = operation;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> open(Skill skill, {bool restart = false}) async {
    await controller.begin(skill, restart: restart);
    await refresh();
    if (mounted) setState(() => selected = skill);
  }

  Future<void> submit(SkillAssessment run, ContentItem item, int choice) async {
    await controller.answer(run, item, choice);
    await refresh();
  }

  String label(Skill skill) =>
      '${skill.name[0].toUpperCase()}${skill.name.substring(1)}';

  @override
  Widget build(BuildContext context) {
    final run = runs[selected];
    final reason = selected == null
        ? null
        : controller.unavailable(selected!, run);
    final item = run == null || reason != null ? null : controller.next(run);
    final reading = run == null || reason != null
        ? null
        : controller.nextReading(run);
    final finished = runs.values.where((r) => r.complete).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Your starting point')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '$finished of 7 skill checks complete',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text(
                'Each check takes 6–8 activities and saves every answer. You can leave and resume later. Unavailable skills stay unassessed.',
              ),
              const SizedBox(height: 20),
              if (busy) const LinearProgressIndicator(),
              if (error != null) ...[
                Text(error!, semanticsLabel: error),
                FilledButton(
                  onPressed: busy || retry == null
                      ? null
                      : () => perform(retry!),
                  child: const Text('Retry'),
                ),
              ],
              if (selected == null) ...[
                for (final skill in Skill.values)
                  Card(
                    child: ListTile(
                      title: Text(label(skill)),
                      subtitle: Text(
                        runs[skill]?.complete == true
                            ? 'Complete · ${runs[skill]!.answers.length} answers'
                            : controller.unavailable(skill, runs[skill]) ??
                                  (runs[skill] == null
                                      ? 'Ready to begin'
                                      : '${runs[skill]!.answers.length} answers saved · Resume'),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: busy
                          ? null
                          : () {
                              if (runs[skill] != null ||
                                  controller.unavailable(skill, null) != null) {
                                setState(() => selected = skill);
                              } else {
                                perform(() => open(skill));
                              }
                            },
                    ),
                  ),
              ] else ...[
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => selected = null),
                  child: const Text('All skill checks'),
                ),
                Text(
                  label(selected!),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                if (run?.complete == true) ...[
                  Text(
                    'Check complete. ${run!.answers.length} answers saved. Your skill profile includes this evidence.',
                  ),
                  const SizedBox(height: 12),
                  const Text('The other skills still need their own checks.'),
                ] else if (reason != null) ...[
                  Text(reason),
                  if (run != null &&
                      controller.unavailable(selected!, null) == null)
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => perform(() => open(selected!, restart: true)),
                      child: const Text('Start a new check'),
                    ),
                ] else if (reading != null) ...[
                  Text(
                    'Passage ${run!.answers.length + 1} of up to 8 · Level ${run.staircase.difficulty + 1}',
                  ),
                  const SizedBox(height: 16),
                  Text(reading.title),
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => perform(() async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ReadingPage(
                                  session: widget.session,
                                  passage: reading,
                                  assessment: run,
                                ),
                              ),
                            );
                            await refresh();
                          }),
                    icon: const Icon(Icons.mic_none),
                    label: const Text('Read this passage'),
                  ),
                ] else if (item != null) ...[
                  Text(
                    'Question ${run!.answers.length + 1} of up to 8 · Level ${run.staircase.difficulty + 1}',
                  ),
                  const SizedBox(height: 20),
                  Text(
                    item.prompt,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 20),
                  for (var choice = 0; choice < item.options.length; choice++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: OutlinedButton(
                        onPressed: busy || error != null
                            ? null
                            : () => perform(() => submit(run, item, choice)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.all(20),
                        ),
                        child: Text(item.options[choice]),
                      ),
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
