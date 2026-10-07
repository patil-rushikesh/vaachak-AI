import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'lesson_recordings.dart';
import 'practice_assignments_page.dart';
import 'school_connection.dart';
import 'school_providers.dart';
import 'school_transfer_page.dart';
import 'session.dart';
import 'password_sign_in.dart';

class SchoolPage extends ConsumerStatefulWidget {
  final LearningSession session;
  const SchoolPage({super.key, required this.session});
  @override
  ConsumerState<SchoolPage> createState() => _SchoolPageState();
}

class _SchoolPageState extends ConsumerState<SchoolPage> {
  final code = TextEditingController(), witness = TextEditingController();
  bool busy = false, consent = false;
  String? message;
  @override
  void dispose() {
    code.dispose();
    witness.dispose();
    super.dispose();
  }

  Future<void> act(Future<void> Function() work) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await work();
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Could not complete this action. Check the code, consent and connection, then retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return Scaffold(
      appBar: AppBar(title: const Text('Your school')),
      bottomNavigationBar: message == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Semantics(liveRegion: true, child: Text(message!)),
              ),
            ),
      body: ref
          .watch(schoolCoordinatorProvider(s.bank))
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Center(
              child: Text(
                'School connection unavailable. Your learning stays saved.',
              ),
            ),
            data: (coordinator) {
              if (coordinator == null) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'This app is not connected to a school. Ask your teacher for the configured app. You can keep learning offline.',
                  ),
                );
              }
              final connection = coordinator.connection;
              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  if (!connection.signedIn) ...[
                    const Text(
                      'Use the account assigned to this device by your school.',
                    ),
                    PasswordSignIn(
                      label: 'School device email',
                      onSignIn: (email, password) async {
                        await connection.signIn(email, password);
                        if (mounted) setState(() {});
                      },
                    ),
                  ] else ...[
                    ValueListenableBuilder<String>(
                      valueListenable: coordinator.status,
                      builder: (_, value, _) => Text(value),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: code,
                      decoration: const InputDecoration(
                        labelText: 'Class joining code',
                      ),
                    ),
                    if (s.profile.minor)
                      TextField(
                        controller: witness,
                        decoration: const InputDecoration(
                          labelText: 'Guardian consent document reference',
                        ),
                      ),
                    CheckboxListTile(
                      value: consent,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => consent = v ?? false),
                      title: Text(
                        s.profile.minor
                            ? 'A guardian has agreed to sharing progress with this school; a teacher will verify the reference.'
                            : 'I agree to share my learning progress with this school.',
                      ),
                    ),
                    FilledButton(
                      onPressed: busy || !consent
                          ? null
                          : () => act(() async {
                              if (!s.ready) throw StateError('Profile locked');
                              if (s.profile.minor &&
                                  witness.text.trim().length < 6) {
                                throw StateError('Guardian reference required');
                              }
                              await s.store.setConsent(
                                s.profile.id,
                                'serverSync',
                                true,
                                witnessReference: witness.text.trim(),
                              );
                              final result = await coordinator.sync.join(
                                s.profile,
                                code.text.trim(),
                              );
                              await s.reloadProgress();
                              if (mounted) {
                                setState(
                                  () => message =
                                      '${result['className']}: ${result['status']}. Your teacher must approve enrollment before progress is shared.',
                                );
                              }
                            }),
                      child: const Text('Request to join class'),
                    ),
                    OutlinedButton(
                      onPressed: busy ? null : () => act(coordinator.run),
                      child: const Text('Sync now'),
                    ),
                    FilledButton.tonal(
                      onPressed: busy
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PracticeAssignmentsPage(
                                  service: LessonRecordingService(
                                    connection.client,
                                    connection.api,
                                    SchoolConnection.environment,
                                  ),
                                ),
                              ),
                            ),
                      child: const Text('Practice from your teacher'),
                    ),
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => SchoolTransferPage(
                                  sync: coordinator.sync,
                                  learnerId: s.profile.id,
                                ),
                              ),
                            ),
                      child: const Text('Offline school transfer'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => act(() async {
                              await s.store.setConsent(
                                s.profile.id,
                                'serverSync',
                                false,
                              );
                              await s.reloadProgress();
                              await coordinator.run();
                              if (mounted) {
                                setState(
                                  () => message =
                                      'Progress sharing stopped. Revocation is queued if offline.',
                                );
                              }
                            }),
                      child: const Text('Stop sharing progress'),
                    ),
                    TextButton(
                      onPressed: busy ? null : () => act(connection.signOut),
                      child: const Text('Sign out of school account'),
                    ),
                  ],
                  if (busy) const LinearProgressIndicator(),
                ],
              );
            },
          ),
    );
  }
}
