import 'journey_dashboard.dart';
import 'school_transfer_page.dart';
import 'school_providers.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'offline_providers.dart';
import 'learner_presentation.dart';
import 'package:flutter/services.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/vaachak_store.dart';
import 'learner.dart';
import 'session.dart';
import 'updates.dart';
import 'pack_page.dart';
import 'teacher.dart' as teacher;

class PlatformHome extends ConsumerStatefulWidget {
  final ContentBank bank;
  const PlatformHome({super.key, required this.bank});
  @override
  ConsumerState<PlatformHome> createState() => _HomeState();
}

class _HomeState extends ConsumerState<PlatformHome>
    with WidgetsBindingObserver {
  final updates = AppUpdateService();
  VaachakStore? store;
  List<LocalProfile> profiles = [];
  LearningSession? get session => ref.read(offlineSessionProvider).session;
  String? error;
  Timer? lock;
  bool get hindi => ref.read(interfaceLocaleProvider) == 'hi';
  String tr(String en, String hi) => hindi ? hi : en;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(activity);
    HardwareKeyboard.instance.addHandler(keyActivity);
    initialize();
    unawaited(updates.recover());
  }

  Future<void> initialize() async {
    try {
      final opened = await ref.read(offlineStoreProvider.future);
      if (!mounted) return;
      store = opened;
      final locale = await opened.metadata('interface.locale');
      if (!mounted) return;
      if (locale == 'en' || locale == 'hi') {
        ref.read(interfaceLocaleProvider.notifier).select(locale!);
      }
      await refresh();
    } catch (_) {
      if (mounted) setState(() => error = 'storage');
    }
  }

  Future<void> refresh() async {
    try {
      ref.invalidate(localProfilesProvider);
      final result = await ref.read(localProfilesProvider.future);
      if (mounted) {
        setState(() {
          profiles = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'storage');
    }
  }

  Future<void> changeLanguage() async {
    final locale = hindi ? 'en' : 'hi';
    ref.read(interfaceLocaleProvider.notifier).select(locale);
    try {
      await store?.setMetadata('interface.locale', locale);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'Language changed for this visit; it could not be saved.',
                'भाषा अभी बदल गई है; इसे सहेजा नहीं जा सका।',
              ),
            ),
          ),
        );
      }
    }
  }

  void activity(PointerEvent event) {
    if (event is PointerDownEvent && mounted) touch();
  }

  bool keyActivity(KeyEvent event) {
    if (mounted) touch();
    return false;
  }

  void touch() {
    lock?.cancel();
    if (session != null) {
      lock = Timer(const Duration(minutes: 5), lockNow);
    }
  }

  void lockNow() {
    lock?.cancel();
    ref.read(offlineSessionProvider.notifier).lock();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(updates.recover());
    if (state == AppLifecycleState.paused) {
      lockNow();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(activity);
    HardwareKeyboard.instance.removeHandler(keyActivity);
    lock?.cancel();
    updates.dispose();
    // The provider scope owns storage and active-session disposal.
    super.dispose();
  }

  Future<void> unlock(LocalProfile profile) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UnlockDialog(
      store: store!,
      bank: widget.bank,
      profile: profile,
      hindi: hindi,
      onUnlocked: () {
        if (!mounted) return;
        ref.read(interfaceLocaleProvider.notifier).select(profile.locale);
        touch();
      },
    ),
  );

  Future<void> create() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CreateProfile(store: store!, hindi: hindi),
      ),
    );
    if (result == true) {
      await refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(schoolCoordinatorProvider(widget.bank));
    ref.listen(offlineSessionProvider, (previous, next) {
      if (previous?.session != null && next.session == null && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
    ref.watch(offlineSessionProvider);
    ref.watch(interfaceLocaleProvider);
    if (session != null) {
      return Listener(
        onPointerDown: (_) => touch(),
        child: LearnerHome(
          session: session!,
          onLock: lockNow,
          onErased: () async {
            lockNow();
            await refresh();
          },
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('VaachakAI'),
        actions: [
          TextButton(
            onPressed: changeLanguage,
            child: Text(hindi ? 'English' : 'हिन्दी'),
          ),
          PopupMenuButton<String>(
            tooltip: tr('More options', 'अन्य विकल्प'),
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (value) async {
              if (value == 'teacher') {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => teacher.PlatformHome(bank: widget.bank),
                  ),
                );
              } else if (value == 'packs') {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PackPage()),
                );
              } else if (value == 'updates') {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => UpdatePage(service: updates),
                  ),
                );
              } else if (value == 'transfer') {
                final coordinator = await ref.read(
                  schoolCoordinatorProvider(widget.bank).future,
                );
                if (!context.mounted) return;
                if (coordinator == null || !coordinator.connection.signedIn) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Open a learner profile and sign in to your school first.',
                      ),
                    ),
                  );
                  return;
                }
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SchoolTransferPage(sync: coordinator.sync),
                  ),
                );
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'teacher',
                child: Text(tr('Teacher portal', 'शिक्षक पोर्टल')),
              ),
              PopupMenuItem(
                value: 'packs',
                child: Text(tr('Offline packs', 'ऑफ़लाइन पैक')),
              ),
              PopupMenuItem(
                value: 'updates',
                child: Text(tr('Check for app updates', 'ऐप अपडेट जाँचें')),
              ),
              PopupMenuItem(
                value: 'transfer',
                child: Text(tr('School transfers', 'स्कूल ट्रांसफ़र')),
              ),
            ],
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(28),
            children: [
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: journeyLime,
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Center(child: JourneyBuddy(size: 142)),
                    const SizedBox(height: 16),
                    Text(
                      tr(
                        'Big adventures.\nLittle lessons.',
                        'छोटे अभ्यास।\nबड़ी उड़ान।',
                      ),
                      style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w900,
                        height: 1.08,
                        letterSpacing: -1.2,
                        color: journeyInk,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      tr(
                        'Discover your English voice. One happy little step at a time.',
                        'अंग्रेज़ी में अपना आत्मविश्वास खोजें। एक बार में एक छोटा कदम।',
                      ),
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.4,
                        color: journeyInk,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const Icon(
                          Icons.cloud_done_outlined,
                          color: journeyGreen,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr(
                              'Learn anywhere. Even offline.',
                              'कहीं भी सीखें। इंटरनेट के बिना भी।',
                            ),
                            style: const TextStyle(
                              color: journeyGreen,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              if (error != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Text(
                          tr(
                            'Encrypted storage could not be opened. Existing data has not been replaced. Check free space and restore a verified backup if needed.',
                            'एन्क्रिप्टेड स्टोरेज नहीं खुल सका। पुराना डेटा नहीं बदला गया है। जगह जाँचें और ज़रूरत हो तो सत्यापित बैकअप बहाल करें।',
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            ref.invalidate(offlineStoreProvider);
                            setState(() {
                              store = null;
                              error = null;
                            });
                            initialize();
                          },
                          child: Text(tr('Retry', 'फिर कोशिश करें')),
                        ),
                      ],
                    ),
                  ),
                )
              else if (store == null)
                const Center(child: CircularProgressIndicator())
              else ...[
                Text(
                  tr('Who is learning today?', 'आज कौन सीख रहा है?'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                for (final p in profiles)
                  Card(
                    child: ListTile(
                      minVerticalPadding: 18,
                      leading: const CircleAvatar(
                        backgroundColor: journeyLime,
                        child: Icon(Icons.face_rounded, color: journeyGreen),
                      ),
                      title: Text(p.name),
                      trailing: const Icon(Icons.lock_outline),
                      onTap: () => unlock(p),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: create,
                  icon: const Icon(Icons.add),
                  label: Text(
                    tr('Create a learner profile', 'नई प्रोफ़ाइल बनाएँ'),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  tr(
                    'Profiles are protected by a PIN. Voice recordings are not saved.',
                    'प्रोफ़ाइल पिन से सुरक्षित हैं। आवाज़ की रिकॉर्डिंग सहेजी नहीं जाती।',
                  ),
                  textAlign: TextAlign.center,
                ),
                if (const bool.fromEnvironment('ALLOW_DRAFT_CONTENT'))
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      tr(
                        'Development build · draft content for evaluation only',
                        'परीक्षण संस्करण · केवल मूल्यांकन के लिए असमीक्षित सामग्री',
                      ),
                      textAlign: TextAlign.center,
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

class _UnlockDialog extends ConsumerStatefulWidget {
  final VaachakStore store;
  final ContentBank bank;
  final LocalProfile profile;
  final bool hindi;
  final VoidCallback onUnlocked;
  const _UnlockDialog({
    required this.store,
    required this.bank,
    required this.profile,
    required this.hindi,
    required this.onUnlocked,
  });
  @override
  ConsumerState<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends ConsumerState<_UnlockDialog> {
  final pin = TextEditingController();
  bool busy = false;
  String? message;
  String tr(String en, String hi) => widget.hindi ? hi : en;
  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await ref
          .read(offlineSessionProvider.notifier)
          .unlock(widget.store, widget.bank, widget.profile.id, pin.text);
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      Navigator.pop(context);
      widget.onUnlocked();
    } catch (exception) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      if (exception is UnlockCancelled) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        busy = false;
        message = exception is PinRejected
            ? tr(
                'PIN did not match, or this profile is temporarily locked.',
                'पिन गलत है या प्रोफ़ाइल कुछ समय के लिए बंद है।',
              )
            : tr(
                'The profile could not be opened. Check storage and learning consent, then retry.',
                'प्रोफ़ाइल नहीं खुल सकी। स्टोरेज और सीखने की सहमति जाँचकर फिर कोशिश करें।',
              );
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(
        tr('Unlock ${widget.profile.name}', '${widget.profile.name} खोलें'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 12,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: tr('Your PIN', 'आपका पिन'),
                errorText: message,
                errorMaxLines: 4,
              ),
            ),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(tr('Cancel', 'रद्द करें')),
        ),
        FilledButton(
          onPressed: busy ? null : submit,
          child: Text(tr('Continue', 'आगे बढ़ें')),
        ),
      ],
    ),
  );
}

class CreateProfile extends StatefulWidget {
  final VaachakStore store;
  final bool hindi;
  const CreateProfile({super.key, required this.store, required this.hindi});
  @override
  State<CreateProfile> createState() => _CreateProfileState();
}

class _CreateProfileState extends State<CreateProfile> {
  final name = TextEditingController(),
      pin = TextEditingController(),
      witness = TextEditingController();
  AgeBand age = AgeBand.student;
  bool minor = true, consent = false, busy = false;
  String? error;
  String tr(String en, String hi) => widget.hindi ? hi : en;
  @override
  void dispose() {
    name.dispose();
    pin.dispose();
    witness.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!consent) {
      setState(() => error = tr('Consent is required.', 'सहमति आवश्यक है।'));
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.store.createProfile(
        name: name.text,
        age: age,
        minor: minor,
        locale: widget.hindi ? 'hi' : 'en',
        pin: pin.text,
        consentMethod: minor ? 'teacherWitnessedPaper' : 'self',
        witnessReference: minor ? witness.text : null,
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = tr(
            'Check the name, 6–12 digit PIN and consent reference.',
            'नाम, 6–12 अंकों का पिन और सहमति संदर्भ जाँचें।',
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr('Make yourself at home', 'अपनी प्रोफ़ाइल बनाएँ')),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            TextField(
              controller: name,
              maxLength: 60,
              decoration: InputDecoration(
                labelText: tr('First name or nickname', 'नाम या उपनाम'),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<AgeBand>(
              initialValue: age,
              decoration: InputDecoration(
                labelText: tr('Learning style', 'सीखने की शैली'),
              ),
              items: AgeBand.values
                  .map(
                    (a) => DropdownMenuItem(
                      value: a,
                      child: Text(
                        LearnerStrings(widget.hindi ? 'hi' : 'en').age(a),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() {
                age = v!;
                if (age == AgeBand.child) {
                  minor = true;
                }
              }),
            ),
            CheckboxListTile(
              value: minor,
              onChanged: age == AgeBand.child
                  ? null
                  : (v) => setState(() => minor = v!),
              title: Text(
                tr('Learner is under 18', 'सीखने वाले की आयु 18 से कम है'),
              ),
            ),
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 12,
              decoration: InputDecoration(
                labelText: tr(
                  'Choose a 6–12 digit PIN',
                  '6–12 अंकों का पिन चुनें',
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                'Learning progress is stored encrypted on this device. Server sync, microphone use and telemetry are separate choices. You can export or erase this profile from its dashboard.',
                'सीखने की प्रगति इस डिवाइस पर एन्क्रिप्ट की जाती है। सर्वर सिंक और माइक्रोफ़ोन के लिए अलग सहमति चाहिए। डैशबोर्ड से डेटा मिटा सकते हैं।',
              ),
            ),
            if (minor) ...[
              const SizedBox(height: 16),
              Text(
                tr(
                  'A teacher must first witness the guardian’s signed consent. Enter its school record reference below.',
                  'पहले शिक्षक को अभिभावक की हस्ताक्षरित सहमति की पुष्टि करनी होगी। नीचे स्कूल रिकॉर्ड का संदर्भ दें।',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: witness,
                decoration: InputDecoration(
                  labelText: tr(
                    'Witnessed consent reference',
                    'सत्यापित सहमति संदर्भ',
                  ),
                ),
              ),
            ],
            CheckboxListTile(
              value: consent,
              onChanged: (v) => setState(() => consent = v!),
              title: Text(
                tr(
                  minor
                      ? 'Guardian consent has been verified for learning on this device.'
                      : 'I consent to storing my progress for learning on this device.',
                  'इस डिवाइस पर सीखने की प्रगति सहेजने की सहमति है।',
                ),
              ),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : save,
              child: Text(
                busy
                    ? tr('Creating…', 'बन रहा है…')
                    : tr('Create profile', 'प्रोफ़ाइल बनाएँ'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
