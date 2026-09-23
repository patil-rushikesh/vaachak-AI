import 'dart:async';
import 'journey_dashboard.dart';
import 'school_page.dart';
import 'privacy_controls.dart';
import 'package:flutter/material.dart';
import 'explanation_runtime.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_explain/vaachak_explain.dart';
import 'session.dart';
import 'learner_presentation.dart';
import 'package:vaachak_store/vaachak_store.dart';
import 'reading_page.dart';
import 'assessment_page.dart';

class LearnerHome extends StatefulWidget {
  final LearningSession session;
  final VoidCallback onLock;
  final Future<void> Function() onErased;
  const LearnerHome({
    super.key,
    required this.session,
    required this.onLock,
    required this.onErased,
  });
  @override
  State<LearnerHome> createState() => _LearnerHomeState();
}

class _LearnerHomeState extends State<LearnerHome> {
  LearningSession get s => widget.session;
  String tr(String en, String hi) => s.profile.locale == 'hi' ? hi : en;
  @override
  void initState() {
    super.initState();
    s.addListener(changed);
  }

  @override
  void dispose() {
    s.removeListener(changed);
    super.dispose();
  }

  void changed() {
    if (mounted) {
      setState(() {});
    }
  }

  Widget themed(Widget child) => Theme(
    data: learnerTheme(
      Theme.of(context),
      s.profile.age,
      highContrast: MediaQuery.highContrastOf(context),
    ),
    child: child,
  );

  Future<void> practice(Recommendation recommendation) async {
    final items = s.items(recommendation.node.id).take(5).toList();
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'This skill needs a reviewed content pack. Try another available activity.',
              'इस कौशल के लिए समीक्षा किया हुआ कंटेंट पैक चाहिए।',
            ),
          ),
        ),
      );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Theme(
          data: learnerTheme(
            Theme.of(context),
            s.profile.age,
            highContrast: MediaQuery.highContrastOf(context),
          ),
          child: PracticePage(
            session: s,
            items: items,
            title: recommendation.node.name,
          ),
        ),
      ),
    );
  }

  Future<void> privacy() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Your data, your choice', 'आपका डेटा, आपका निर्णय'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(
                  tr(
                    'Your progress stays encrypted on this device. Audio is not saved. Deleting a profile removes its progress; an erasure notice remains queued for paired devices.',
                    'प्रगति एन्क्रिप्टेड है। आवाज़ नहीं सहेजी जाती। प्रोफ़ाइल मिटाने पर प्रगति हटती है और जुड़े डिवाइस के लिए मिटाने की सूचना बनती है।',
                  ),
                ),
                const SizedBox(height: 16),
                PrivacyControls(session: s),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final data = await s.store.exportLearner(s.profile.id);
                      if (!context.mounted || !mounted || !s.ready) return;
                      Navigator.pop(context);
                      showDialog<void>(
                        context: this.context,
                        builder: (context) => AlertDialog(
                          title: Text(tr('Progress export', 'प्रगति निर्यात')),
                          content: SizedBox(
                            width: 600,
                            child: SingleChildScrollView(
                              child: SelectableText(data),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(tr('Close', 'बंद करें')),
                            ),
                          ],
                        ),
                      );
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr(
                                'Progress could not be exported. Check storage and retry.',
                                'प्रगति निर्यात नहीं हुई। स्टोरेज जाँचकर फिर कोशिश करें।',
                              ),
                            ),
                          ),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.download),
                  label: Text(
                    tr('View progress export', 'प्रगति निर्यात देखें'),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(
                          tr('Erase this learner?', 'इस प्रोफ़ाइल को मिटाएँ?'),
                        ),
                        content: Text(
                          tr(
                            'This permanently removes this profile and learning history from this device.',
                            'प्रोफ़ाइल और सीखने का इतिहास इस डिवाइस से स्थायी रूप से हट जाएगा।',
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(tr('Cancel', 'रद्द करें')),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(tr('Erase', 'मिटाएँ')),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      try {
                        await s.store.erase(s.profile.id);
                        if (context.mounted) {
                          Navigator.pop(context);
                        }
                        await widget.onErased();
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                tr(
                                  'Erasure did not complete. Please try again.',
                                  'डेटा पूरी तरह नहीं मिटा। फिर कोशिश करें।',
                                ),
                              ),
                            ),
                          );
                        }
                      }
                    }
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: Text(
                    tr(
                      'Erase profile and progress',
                      'प्रोफ़ाइल और प्रगति मिटाएँ',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = LearnerStrings(s.profile.locale);
    final now = DateTime.now();
    final evidence = s.snapshot.evidenceIds.toSet();
    final today = s.history
        .where((event) {
          final date = DateTime.fromMillisecondsSinceEpoch(
            event.hlc.millis,
          ).toLocal();
          return evidence.contains(event.id) &&
              event.learnerId == s.profile.id &&
              date.year == now.year &&
              date.month == now.month &&
              date.day == now.day &&
              !date.isAfter(now);
        })
        .map((event) => event.id)
        .toSet()
        .length;
    final progress = LearnerProgress.from(
      s.bank.graph,
      s.profile.id,
      s.history,
      now: now,
      dayOffset: now.timeZoneOffset,
    );
    void open(Widget page) => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => themed(page)),
    );
    return Theme(
      data: learnerTheme(
        Theme.of(context),
        s.profile.age,
        highContrast: MediaQuery.highContrastOf(context),
      ),
      child: JourneyDashboard(
        key: ValueKey('dashboard-${s.profile.age.name}'),
        name: s.profile.name,
        locale: s.profile.locale,
        age: s.profile.age.name,
        today: today,
        weekly: progress.attemptsThisWeek,
        activeDays: progress.activeDaysThisWeek,
        lessons: [
          for (final recommendation in s.path)
            JourneyLesson(
              recommendation.node.name,
              '${text.skill(recommendation.node.skill)} · ${s.items(recommendation.node.id).length.clamp(0, 5)} ${tr('questions', 'सवाल')}',
              () => practice(recommendation),
            ),
        ],
        skills: [
          for (final skill in progress.skills)
            JourneySkill(
              text.skill(skill.skill),
              skill.mean == null
                  ? tr('Ready to discover', 'खोजने के लिए तैयार')
                  : '${text.band(Mastery(learned: skill.mean!, observations: skill.observations))} · ${text.evidence(skill.observations)}',
              skill.mean,
            ),
        ],
        onReading: () => open(ReadingPage(session: s)),
        onGrammar: () => open(GrammarPage(session: s)),
        onCheck: () => open(AssessmentPage(session: s)),
        onSchool: () => open(SchoolPage(session: s)),
        onPrivacy: privacy,
        onLock: widget.onLock,
      ),
    );
  }
}

class PracticePage extends StatefulWidget {
  final LearningSession session;
  final List<ContentItem> items;
  final String title;
  const PracticePage({
    super.key,
    required this.session,
    required this.items,
    required this.title,
  });
  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage> {
  int index = 0, correct = 0;
  String attemptId = newUlid();
  String tr(String en, String hi) =>
      widget.session.profile.locale == 'hi' ? hi : en;
  int? selected;
  bool saved = false, busy = false;
  String? error;
  Future<void> submit(int choice) async {
    if (busy || saved) {
      return;
    }
    setState(() {
      selected = choice;
      busy = true;
      error = null;
    });
    try {
      await widget.session.answer(
        widget.items[index],
        choice,
        attemptId: attemptId,
      );
      if (mounted) {
        setState(() {
          saved = true;
          if (choice == widget.items[index].answer) correct++;
          busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = tr(
            'Progress could not be saved. Check storage and learning consent, then retry this answer.',
            'प्रगति नहीं सहेजी जा सकी। स्टोरेज और सीखने की सहमति जाँचकर इसी उत्तर को फिर सहेजें।',
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[index];
    return Scaffold(
      backgroundColor: journeyPaper,
      appBar: AppBar(backgroundColor: journeyPaper, title: Text(widget.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              LinearProgressIndicator(
                value: (index + (saved ? 1 : 0)) / widget.items.length,
                minHeight: 10,
                borderRadius: BorderRadius.circular(12),
                color: journeyGreen,
                backgroundColor: const Color(0xffe3e9dc),
              ),
              const SizedBox(height: 16),
              Text(
                tr(
                  'STEP ${index + 1} OF ${widget.items.length}',
                  '${widget.items.length} में से चरण ${index + 1}',
                ),
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 32),
              Text(
                item.prompt,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 28),
              for (var i = 0; i < item.options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: OutlinedButton(
                    onPressed: busy || saved
                        ? null
                        : () => setState(() => selected = i),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      backgroundColor: selected == i
                          ? journeyLime
                          : Colors.white,
                      side: BorderSide(
                        color: selected == i
                            ? journeyGreen
                            : const Color(0xffdce3d6),
                        width: 2,
                      ),
                      padding: const EdgeInsets.all(20),
                    ),
                    child: Text(
                      item.options[i],
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
              if (!saved && error == null)
                FilledButton.icon(
                  onPressed: selected == null || busy
                      ? null
                      : () => submit(selected!),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(tr('Check answer', 'उत्तर जाँचें')),
                ),
              if (busy) const LinearProgressIndicator(),
              if (error != null) ...[
                Text(error!, style: const TextStyle(color: Colors.red)),
                TextButton(
                  onPressed: () => submit(selected!),
                  child: Text(tr('Retry saving', 'फिर सहेजें')),
                ),
              ],
              if (saved) ...[
                const SizedBox(height: 20),
                Card(
                  color: selected == item.answer
                      ? const Color(0xffe3efcf)
                      : const Color(0xffffe8d8),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      selected == item.answer
                          ? tr(
                              'That’s right. Keep going!',
                              'सही जवाब! आगे बढ़ें।',
                            )
                          : tr(
                              'The answer is “${item.options[item.answer]}”. Take a moment to read it again.',
                              'उत्तर है “${item.options[item.answer]}”। इसे फिर पढ़ें।',
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    if (index + 1 == widget.items.length) {
                      await showDialog<void>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          icon: const JourneyBuddy(size: 100),
                          title: Text(
                            tr(
                              'You showed up. You grew!',
                              'आपने अभ्यास किया। आप आगे बढ़े!',
                            ),
                          ),
                          content: Text(
                            tr(
                              '$correct of ${widget.items.length} correct. Every answer is saved. Ready for your next little win?',
                              '${widget.items.length} में से $correct सही। सभी उत्तर सुरक्षित हैं।',
                            ),
                          ),
                          actions: [
                            FilledButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: Text(
                                tr('Back to my trail', 'अपने सफ़र पर लौटें'),
                              ),
                            ),
                          ],
                        ),
                      );
                      if (context.mounted) Navigator.pop(context);
                    } else {
                      setState(() {
                        index++;
                        attemptId = newUlid();
                        selected = null;
                        saved = false;
                      });
                    }
                  },
                  child: Text(
                    index + 1 == widget.items.length
                        ? tr('Back to your path', 'अपने रास्ते पर लौटें')
                        : tr('Next question', 'अगला प्रश्न'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class GrammarPage extends StatefulWidget {
  final LearningSession session;
  final ExplanationModel Function()? explanationModelFactory;
  const GrammarPage({
    super.key,
    required this.session,
    this.explanationModelFactory,
  });
  @override
  State<GrammarPage> createState() => _GrammarPageState();
}

class _GrammarPageState extends State<GrammarPage> with WidgetsBindingObserver {
  String tr(String en, String hi) =>
      widget.session.profile.locale == 'hi' ? hi : en;
  final text = TextEditingController();
  GrammarCorrection? correction;
  Explanation? explanation;
  ExplanationService? explainer;
  bool explaining = false;
  int explanationGeneration = 0;
  String? explanationNotice;
  String? message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void stopExplanation() {
    explanationGeneration++;
    final old = explainer;
    explainer = null;
    unawaited(old?.close());
    explaining = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      stopExplanation();
    }
  }

  Future<void> improveExplanation() async {
    final c = correction;
    if (c == null ||
        !widget.session.ready ||
        widget.session.profile.age == AgeBand.child ||
        explaining) {
      return;
    }
    stopExplanation();
    final generation = explanationGeneration;
    final service = ExplanationService(
      widget.session.bank.grammar,
      model: widget.explanationModelFactory?.call() ?? LazyExplanationModel(),
      enabled: true,
    );
    explainer = service;
    setState(() {
      explaining = true;
      explanationNotice = null;
    });
    await for (final result in service.explain(c, widget.session.profile.age)) {
      if (!mounted ||
          generation != explanationGeneration ||
          !widget.session.ready) {
        break;
      }
      setState(() => explanation = result);
    }
    if (mounted && generation == explanationGeneration) {
      setState(() {
        explaining = false;
        if (explanation?.source != 'model') {
          explanationNotice = tr(
            'The reviewed explanation is ready. An optional signed explainer pack and a supported device are needed for a local rewording.',
            'समीक्षित समझाइश तैयार है। स्थानीय मॉडल के लिए हस्ताक्षरित पैक और समर्थित डिवाइस चाहिए।',
          );
        }
      });
    }
    await service.close();
  }

  bool busy = false;
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stopExplanation();
    text.dispose();
    super.dispose();
  }

  Future<void> check() async {
    stopExplanation();
    setState(() {
      busy = true;
      explanation = null;
      explanationNotice = null;
      correction = null;
    });
    try {
      if (!const bool.fromEnvironment('ALLOW_DRAFT_CONTENT') &&
          widget.session.bank.grammar.rules.any((r) => !r.approved)) {
        setState(
          () => message = tr(
            'Install a reviewed content pack to use the grammar coach.',
            'व्याकरण अभ्यास के लिए समीक्षित सामग्री का पैक इंस्टॉल करें।',
          ),
        );
        return;
      }
      final c = widget.session.bank.grammar.check(text.text);
      if (c != null) {
        await widget.session.grammarViewed(c);
      }
      if (mounted) {
        setState(() {
          correction = c;
          message = c == null
              ? tr(
                  'No matching pattern found. This checks a limited set of grammar rules; it is not a full grammar assessment.',
                  'कोई मिलती-जुलती त्रुटि नहीं मिली। यह सीमित व्याकरण नियमों की जाँच है, पूरा आकलन नहीं।',
                )
              : null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = tr(
            'The correction could not be saved. Check storage and try again.',
            'सुधार नहीं सहेजा जा सका। स्टोरेज जाँचकर फिर कोशिश करें।',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr('One sentence, one step', 'एक वाक्य, एक कदम')),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              tr('Make your meaning clear.', 'अपनी बात स्पष्ट कहें।'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                'Write a sentence. We’ll focus on one useful correction.',
                'एक वाक्य लिखें। हम एक उपयोगी सुधार पर ध्यान देंगे।',
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: text,
              maxLines: 3,
              maxLength: 2000,
              decoration: InputDecoration(
                labelText: tr('Your sentence', 'आपका वाक्य'),
                hintText: 'She go to school every day.',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : check,
              child: Text(tr('Check my sentence', 'मेरा वाक्य जाँचें')),
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text(message!),
              ),
            if (correction != null) ...[
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('TRY THIS', 'ऐसे लिखें')),
                      const SizedBox(height: 12),
                      SelectableText(
                        correction!.corrected,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        explanation?.text ??
                            ExplanationService(widget.session.bank.grammar)
                                .template(
                                  correction!,
                                  widget.session.profile.age,
                                )
                                .text,
                      ),
                      if (widget.session.profile.age != AgeBand.child) ...[
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: explaining ? null : improveExplanation,
                          child: Text(
                            explaining
                                ? tr(
                                    'Rewording on this device…',
                                    'डिवाइस पर समझा रहे हैं…',
                                  )
                                : tr(
                                    'Try a local rewording',
                                    'स्थानीय मॉडल से समझाएँ',
                                  ),
                          ),
                        ),
                        if (explanationNotice != null) Text(explanationNotice!),
                        if (explanation?.source == 'model')
                          Text(
                            tr(
                              'Reworded on this device',
                              'इसी डिवाइस पर तैयार',
                            ),
                          ),
                      ],
                      const SizedBox(height: 20),
                      Text(tr('READ THESE EXAMPLES', 'ये उदाहरण पढ़ें')),
                      for (final p
                          in explanation?.practice ?? correction!.rule.practice)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(p),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
