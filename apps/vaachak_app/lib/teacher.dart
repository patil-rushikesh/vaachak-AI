import 'teacher_cache_native.dart'
    if (dart.library.js_interop) 'teacher_cache_web.dart';
import 'dart:async';
import 'class_setup_dialog.dart';
import 'lesson_recordings.dart';
import 'teacher_recording_page.dart';
import 'school_connection.dart';
import 'password_sign_in.dart';
import 'teacher_transfer_native.dart'
    if (dart.library.js_interop) 'teacher_transfer_web.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vaachak_content/vaachak_content.dart';

class PlatformHome extends StatefulWidget {
  final ContentBank bank;
  const PlatformHome({super.key, required this.bank});
  @override
  State<PlatformHome> createState() => _TeacherState();
}

class _TeacherState extends State<PlatformHome> {
  static const environment = String.fromEnvironment(
    'VAACHAK_ENV',
    defaultValue: 'dev',
  );
  SupabaseClient? client;
  SchoolConnection? connection;
  List<Map<String, dynamic>> pending = [];
  String? joinCode;
  bool busy = false, offline = false;
  String? error, selectedClass;
  List<Map<String, dynamic>> classes = [],
      learners = [],
      insights = [],
      states = [];
  @override
  void initState() {
    super.initState();
    if (SchoolConnection.configured) {
      connection = SchoolConnection('teacher');
      client = connection!.client;
      unawaited(restore());
    }
  }

  @override
  void dispose() {
    unawaited(connection?.close());
    super.dispose();
  }

  Future<void> restore() async {
    try {
      await connection!.restore();
      if (connection!.signedIn) await load();
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              error = 'School connection unavailable. Sign in again or retry.',
        );
      }
    }
  }

  Future<void> createCode() async {
    if (offline) return;
    try {
      final code = await connection!.api.rpc('create_join_code', {
        'target_class': selectedClass,
      });
      if (mounted) setState(() => joinCode = code as String);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Unable to create a class code. Check your class assignment.',
        );
      }
    }
  }

  Future<void> createClass() async {
    if (offline) return;
    final args = await showClassSetupDialog(context);
    if (args == null) return;
    try {
      final id = await connection!.api.rpc('create_class', args);
      selectedClass = id as String;
      joinCode = null;
      await refresh();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The classroom was not created. Check the details and your connection.',
        );
      }
    }
  }

  Future<void> recordLesson() async {
    if (offline || selectedClass == null) return;
    final current = classes.firstWhere((c) => c['id'] == selectedClass);
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => TeacherRecordingPage(
          service: LessonRecordingService(
            connection!.client,
            connection!.api,
            SchoolConnection.environment,
          ),
          teacherId: connection!.userId,
          classId: selectedClass!,
          className: classLabel(current),
          learners: learners,
          defaultLanguage: (current['instruction_language'] as String?) ?? 'en',
        ),
      ),
    );
    if (sent == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Recording sent to learners.')));
    }
  }

  Future<void> approveEnrollment(Map<String, dynamic> row, bool approve) async {
    if (offline) return;
    final controller = TextEditingController();
    try {
      String? witness;
      if (approve && (row['learners'] as Map)['minor'] == true) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Verify guardian consent'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Witnessed consent document reference',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Confirm witnessed consent'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        witness = controller.text.trim();
        if (witness.length < 6) throw StateError('Reference required');
      }
      await connection!.api.rpc('review_enrollment', {
        'target_class': selectedClass,
        'target_learner': row['learner_id'],
        'approve': approve,
        'witness_reference': witness,
      });
      await refresh();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Enrollment was not changed. Check assignment and guardian consent reference.',
        );
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> load() async {
    try {
      await loadRemote();
      offline = false;
      await writeTeacherCache(connection!.api.scope, {
        'classes': classes,
        'learners': learners,
        'insights': insights,
        'states': states,
        'selectedClass': selectedClass,
      });
    } catch (_) {
      final cached = await readTeacherCache(connection!.api.scope);
      if (cached == null) rethrow;
      if (mounted) {
        setState(() {
          offline = true;
          pending = [];
          joinCode = null;
          classes = (cached['classes'] as List)
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList();
          learners = (cached['learners'] as List)
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList();
          insights = (cached['insights'] as List)
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList();
          states = (cached['states'] as List)
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList();
          selectedClass = cached['selectedClass'] as String?;
        });
      }
    }
  }

  Future<void> loadRemote() async {
    final schema = client!.schema(environment);
    final roster = await schema.from('classes').select('id,name,standard,section,pincode,state,district,instruction_language')
        .order('name');
    if (!roster.any((c) => c['id'] == selectedClass)) {
      selectedClass = roster.isEmpty ? null : roster.first['id'] as String;
    }
    if (selectedClass == null) {
      if (mounted) {
        setState(() {
          classes = roster;
          learners = [];
          pending = [];
          states = [];
          insights = [];
        });
      }
      return;
    }
    await connection!.api.rpc('refresh_class_insights', {
      'target_class': selectedClass,
    });
    final waiting = await schema
        .from('enrollments')
        .select('learner_id,learners(id,display_name,minor)')
        .eq('class_id', selectedClass!)
        .eq('status', 'pending');
    final enrollment = await schema
        .from('enrollments')
        .select('learner_id,learners(id,display_name)')
        .eq('class_id', selectedClass!)
        .eq('status', 'active');
    final ids = enrollment.map((r) => r['learner_id'] as String).toList();
    final mastery = ids.isEmpty
        ? <Map<String, dynamic>>[]
        : await schema
              .from('learner_node_state')
              .select()
              .inFilter('learner_id', ids);
    final claims = ids.isEmpty
        ? <Map<String, dynamic>>[]
        : await schema
              .from('insights')
              .select()
              .inFilter('learner_id', ids)
              .eq('status', 'open')
              .limit(30);
    if (mounted) {
      setState(() {
        classes = roster;
        pending = waiting;
        learners = enrollment
            .map((e) => (e['learners'] as Map).cast<String, dynamic>())
            .toList();
        states = mastery;
        insights = claims;
      });
    }
  }

  Future<void> refresh() async {
    setState(() => busy = true);
    try {
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The class could not be loaded. Check your connection and assignment.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> intervene(
    Map<String, dynamic> learner,
    String node,
    String kind, {
    String? insight,
  }) async {
    if (offline) return;
    try {
      await client!
          .schema(environment)
          .rpc(
            'teacher_intervene',
            params: {
              'target_learner': learner['id'],
              'target_class': selectedClass,
              'target_node': node,
              'action_kind': kind,
              'insight_id': insight,
            },
          );
      await refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The intervention was not saved. Check your active class assignment.',
            ),
          ),
        );
      }
    }
  }

  Future<void> detail(Map<String, dynamic> learner) async {
    final nodeStates = states
        .where((s) => s['learner_id'] == learner['id'])
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .8,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                learner['display_name'] as String,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              if (nodeStates.isEmpty) const Text('No scored evidence yet.'),
              for (final state in nodeStates)
                Card(
                  child: ListTile(
                    title: Text(
                      widget.bank.graph.nodes[state['node_id']]?.name ??
                          state['node_id'] as String,
                    ),
                    subtitle: Text(
                      '${((state['p_learned'] as num) * 100).round()}% · ${state['n_obs']} attempts',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (kind) =>
                          intervene(learner, state['node_id'] as String, kind),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'pin',
                          child: Text('Pin practice'),
                        ),
                        PopupMenuItem(
                          value: 'assign',
                          child: Text('Assign extra practice'),
                        ),
                        PopupMenuItem(
                          value: 'replace',
                          child: Text('Replace my pinned practice'),
                        ),
                        PopupMenuItem(
                          value: 'unpin',
                          child: Text('Remove from path'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> evidence(Map<String, dynamic> insight) async {
    try {
      final events = await client!
          .schema(environment)
          .from('events')
          .select('id,type,payload')
          .inFilter('id', (insight['evidence_ids'] as List).cast<String>())
          .limit(30);
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Evidence behind this insight'),
          content: SizedBox(
            width: 600,
            child: ListView(
              shrinkWrap: true,
              children: events
                  .map(
                    (e) => ListTile(
                      title: Text(e['type'] as String),
                      subtitle: Text(
                        'Item ${(e['payload'] as Map)['itemId']} · Score ${(e['payload'] as Map)['score']}',
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Evidence is unavailable. Please try again.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = connection?.signedIn == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('VaachakAI  /  Teacher studio'),
        actions: [
          if (signedIn)
            TextButton(
              onPressed: () async {
                await clearTeacherCache(connection!.api.scope);
                await connection!.signOut();
                if (mounted) {
                  setState(() {
                    classes = [];
                    learners = [];
                    states = [];
                    insights = [];
                    selectedClass = null;
                    pending = [];
                    joinCode = null;
                  });
                }
              },
              child: const Text('Sign out'),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: ListView(
            padding: const EdgeInsets.all(28),
            children: [
              Text(
                signedIn
                    ? 'See the learner behind the score.'
                    : 'A clearer picture.\nA more personal lesson.',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 12),
              const Text(
                'Seven skills. Visible evidence. You decide the next step.',
              ),
              const SizedBox(height: 28),
              if (client == null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.school_outlined, size: 44),
                        const SizedBox(height: 18),
                        Text(
                          'Connect your school',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'This teacher portal has not been connected to a school deployment. Ask your administrator for the configured app. No learner data is loaded.',
                        ),
                      ],
                    ),
                  ),
                ),
              if (client != null && !signedIn)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Teacher sign-in',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 20),
                        PasswordSignIn(
                          label: 'School email',
                          onSignIn: (email, password) async {
                            await connection!.signIn(email, password);
                            await load();
                            if (mounted) setState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              if (busy) const LinearProgressIndicator(),
              if (offline)
                const Text(
                  'Offline · showing the last saved class view (up to 24 hours old). Reconnect to verify assignments and make changes.',
                ),
              if (signedIn) ...[
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: selectedClass,
                        decoration: const InputDecoration(
                          labelText: 'Your class',
                        ),
                        items: classes
                            .map(
                              (c) => DropdownMenuItem(
                                value: c['id'] as String,
                                child: Text(classLabel(c)),
                              ),
                            )
                            .toList(),
                        onChanged: (id) {
                          selectedClass = id;
                          joinCode = null;
                          refresh();
                        },
                      ),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      onPressed: busy ? null : refresh,
                      tooltip: 'Refresh class',
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: busy || offline ? null : createClass,
                  icon: const Icon(Icons.add),
                  label: const Text('Create classroom'),
                ),
                if (selectedClass != null)
                  OutlinedButton.icon(
                    onPressed: busy || offline ? null : recordLesson,
                    icon: const Icon(Icons.mic),
                    label: const Text('Record lesson and assign'),
                  ),
                if (selectedClass != null)
                  OutlinedButton(
                    onPressed: busy || offline ? null : createCode,
                    child: const Text('Create 20-minute class code'),
                  ),
                if (joinCode != null) SelectableText('Class code: $joinCode'),
                if (connection != null)
                  teacherTransferButton(context, widget.bank, connection!),
                if (pending.isNotEmpty)
                  Text(
                    'Enrollment requests',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                for (final request in pending)
                  Card(
                    child: ListTile(
                      title: Text(
                        (request['learners'] as Map)['display_name'] as String,
                      ),
                      subtitle: const Text(
                        'Progress is not shared until approved.',
                      ),
                      trailing: Wrap(
                        children: [
                          IconButton(
                            tooltip: 'Approve enrollment',
                            icon: const Icon(Icons.check),
                            onPressed: busy || offline
                                ? null
                                : () => approveEnrollment(request, true),
                          ),
                          IconButton(
                            tooltip: 'Reject enrollment',
                            icon: const Icon(Icons.close),
                            onPressed: busy || offline
                                ? null
                                : () => approveEnrollment(request, false),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    metric(
                      'Active learners',
                      '${learners.length}',
                      Icons.people_outline,
                    ),
                    metric(
                      'Scored attempts',
                      '${states.fold<int>(0, (n, s) => n + (s['n_obs'] as int))}',
                      Icons.fact_check_outlined,
                    ),
                    metric(
                      'Insights to review',
                      '${insights.length}',
                      Icons.lightbulb_outline,
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Text(
                  'Your class, at a glance',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                if (learners.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        'No active learners in this class yet. Enrolments appear after a teacher approves them.',
                      ),
                    ),
                  ),
                for (final learner in learners)
                  Card(
                    child: ListTile(
                      minVerticalPadding: 18,
                      leading: const CircleAvatar(
                        child: Icon(Icons.person_outline),
                      ),
                      title: Text(learner['display_name'] as String),
                      subtitle: Text(
                        '${states.where((s) => s['learner_id'] == learner['id']).length} observed skill nodes',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => detail(learner),
                    ),
                  ),
                const SizedBox(height: 28),
                Text(
                  'Insights with evidence',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                if (insights.isEmpty)
                  const Text(
                    'No new claims to review. Insights appear when there is enough practice evidence.',
                  ),
                for (final insight in insights)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            insight['claim'] as String,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              OutlinedButton(
                                onPressed: () => evidence(insight),
                                child: const Text('View evidence'),
                              ),
                              FilledButton(
                                onPressed: () => intervene(
                                  {'id': insight['learner_id']},
                                  insight['node_id'] as String,
                                  'approve',
                                  insight: insight['id'] as String,
                                ),
                                child: const Text('Approve'),
                              ),
                              TextButton(
                                onPressed: () => intervene(
                                  {'id': insight['learner_id']},
                                  insight['node_id'] as String,
                                  'reject',
                                  insight: insight['id'] as String,
                                ),
                                child: const Text('Mark as incorrect'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 32),
              const Text(
                'Designed for teacher judgment. Recommendations always show their evidence.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget metric(String label, String value, IconData icon) => SizedBox(
    width: 260,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: const Color(0xff14675b)),
            const SizedBox(height: 16),
            Text(value, style: Theme.of(context).textTheme.displaySmall),
            Text(label),
          ],
        ),
      ),
    ),
  );
}
