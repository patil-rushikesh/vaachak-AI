import 'package:flutter/material.dart';

const journeyInk = Color(0xff173c32);
const journeyGreen = Color(0xff205b47);
const journeyLime = Color(0xffd8f38c);
const journeyPaper = Color(0xfff8f7f1);

/// An original, code-drawn companion: no downloaded artwork or network dependency.
class JourneyBuddy extends StatelessWidget {
  final double size;
  const JourneyBuddy({super.key, this.size = 96});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Smiling learning companion',
    image: true,
    child: CustomPaint(size: Size.square(size), painter: _BuddyPainter()),
  );
}

class _BuddyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 100);
    final paint = Paint();
    canvas.drawOval(
      const Rect.fromLTWH(17, 85, 70, 9),
      paint..color = journeyInk.withValues(alpha: .1),
    );
    final body = Path()
      ..moveTo(20, 78)
      ..quadraticBezierTo(6, 56, 25, 28)
      ..quadraticBezierTo(44, 1, 73, 22)
      ..quadraticBezierTo(102, 42, 85, 74)
      ..quadraticBezierTo(67, 98, 44, 81)
      ..quadraticBezierTo(27, 89, 20, 78);
    canvas.drawPath(body, paint..color = journeyGreen);
    canvas.drawOval(
      const Rect.fromLTWH(30, 34, 44, 37),
      paint..color = journeyLime,
    );
    canvas.drawCircle(const Offset(42, 49), 3, paint..color = journeyInk);
    canvas.drawCircle(const Offset(61, 49), 3, paint);
    canvas.drawArc(
      const Rect.fromLTWH(43, 51, 18, 12),
      .15,
      2.8,
      false,
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.8
        ..strokeCap = StrokeCap.round,
    );
    paint.style = PaintingStyle.fill;
    canvas.drawCircle(
      const Offset(35, 57),
      4,
      paint..color = const Color(0xffffbd9d),
    );
    canvas.drawCircle(const Offset(70, 57), 4, paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(11, 61, 17, 9),
        const Radius.circular(6),
      ),
      paint..color = journeyGreen,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(78, 43, 18, 9),
        const Radius.circular(6),
      ),
      paint,
    );
    canvas.drawCircle(
      const Offset(84, 16),
      6,
      paint..color = const Color(0xffffbd75),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class JourneyLesson {
  final String title, subtitle;
  final VoidCallback onTap;
  const JourneyLesson(this.title, this.subtitle, this.onTap);
}

class JourneySkill {
  final String title, detail;
  final double? value;
  const JourneySkill(this.title, this.detail, this.value);
}

class JourneyDashboard extends StatefulWidget {
  final String name, locale, age;
  final int today, weekly, activeDays;
  final List<JourneyLesson> lessons;
  final List<JourneySkill> skills;
  final VoidCallback onReading, onGrammar, onCheck, onSchool, onPrivacy, onLock;
  const JourneyDashboard({
    super.key,
    required this.name,
    required this.locale,
    required this.age,
    required this.today,
    required this.weekly,
    required this.activeDays,
    required this.lessons,
    required this.skills,
    required this.onReading,
    required this.onGrammar,
    required this.onCheck,
    required this.onSchool,
    required this.onPrivacy,
    required this.onLock,
  });
  @override
  State<JourneyDashboard> createState() => _JourneyDashboardState();
}

class _JourneyDashboardState extends State<JourneyDashboard> {
  int tab = 0;
  String tr(String en, String hi) => widget.locale == 'hi' ? hi : en;
  TextStyle heading(double size) => TextStyle(
    fontSize: size,
    height: 1.12,
    fontWeight: FontWeight.w800,
    color: journeyInk,
    letterSpacing: -.6,
  );
  Widget section(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: heading(24)),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: const TextStyle(color: Color(0xff566b61), height: 1.4),
        ),
      ],
    ),
  );
  Widget pill(IconData icon, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: journeyGreen),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: journeyInk,
            ),
          ),
        ),
      ],
    ),
  );
  Widget tile(
    String title,
    String subtitle,
    IconData icon,
    Color color,
    VoidCallback action,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: action,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: journeyInk, size: 26),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: heading(18)),
                    const SizedBox(height: 5),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xff566b61),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.arrow_forward_rounded,
                color: journeyGreen,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget learn() {
    final ready = widget.lessons.isNotEmpty;
    final done = widget.today >= 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            pill(
              Icons.cloud_done_outlined,
              tr('Ready offline', 'ऑफ़लाइन तैयार'),
            ),
            pill(
              Icons.auto_awesome_rounded,
              tr('${widget.today} saved today', 'आज ${widget.today} प्रयास'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          tr('Hello, ${widget.name}.', 'नमस्ते, ${widget.name}।'),
          style: heading(30),
        ),
        const SizedBox(height: 8),
        Text(
          tr(
            widget.age == 'child'
                ? 'A little adventure. A new superpower.'
                : 'Small steps. A more confident you.',
            'छोटे कदम। बढ़ता आत्मविश्वास।',
          ),
          style: const TextStyle(fontSize: 16, color: Color(0xff566b61)),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: journeyLime,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('YOUR NEXT LITTLE WIN', 'आपकी अगली छोटी जीत'),
                          style: const TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.3,
                            fontWeight: FontWeight.w800,
                            color: journeyInk,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          ready
                              ? widget.lessons.first.title
                              : tr(
                                  'Let’s find your\nstarting point',
                                  'आइए शुरुआत करें',
                                ),
                          style: heading(27),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const ExcludeSemantics(child: JourneyBuddy(size: 82)),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                tr(
                  ready
                      ? 'One question at a time. You’ve got this.'
                      : 'See which activities are ready for you.',
                  ready
                      ? 'एक बार में एक सवाल। आप कर सकते हैं।'
                      : 'देखें आपके लिए कौन-से अभ्यास तैयार हैं।',
                ),
                style: const TextStyle(color: journeyInk, height: 1.4),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: ready
                      ? widget.lessons.first.onTap
                      : widget.onCheck,
                  style: FilledButton.styleFrom(
                    backgroundColor: journeyInk,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 17,
                      horizontal: 18,
                    ),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    tr(
                      ready ? 'Start learning' : 'Find an activity',
                      ready ? 'अभ्यास शुरू करें' : 'अभ्यास चुनें',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    done ? Icons.celebration_rounded : Icons.flag_rounded,
                    color: journeyGreen,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tr(
                        done
                            ? 'Little goal, big feeling!'
                            : 'Today’s little goal',
                        done ? 'आज का लक्ष्य पूरा!' : 'आज का छोटा लक्ष्य',
                      ),
                      style: heading(17),
                    ),
                  ),
                  Text(
                    '${widget.today.clamp(0, 3)}/3',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: journeyGreen,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LinearProgressIndicator(
                  value: (widget.today / 3).clamp(0, 1),
                  minHeight: 9,
                  color: journeyGreen,
                  backgroundColor: const Color(0xffeaf0e4),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                tr(
                  done
                      ? 'Three answers saved. Keep exploring, or enjoy a break.'
                      : 'Save 3 answers. Every attempt helps you grow.',
                  done
                      ? 'तीन उत्तर सुरक्षित। अब और सीखें या आराम करें।'
                      : '3 उत्तर सहेजें। हर कोशिश से सीखें।',
                ),
                style: const TextStyle(fontSize: 12, color: Color(0xff566b61)),
              ),
            ],
          ),
        ),
        section(
          tr('Your learning trail', 'आपका सीखने का सफ़र'),
          tr(
            'A small step now. More confidence next.',
            'आज एक छोटा कदम। कल अधिक आत्मविश्वास।',
          ),
        ),
        if (!ready)
          tile(
            tr('Choose a skill check', 'कौशल आकलन चुनें'),
            tr('See available learning activities', 'उपलब्ध अभ्यास देखें'),
            Icons.explore_rounded,
            const Color(0xffffe0ca),
            widget.onCheck,
          ),
        for (var i = 0; i < widget.lessons.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Material(
              color: i == 0 ? const Color(0xffe6eedf) : Colors.white,
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                onTap: widget.lessons[i].onTap,
                borderRadius: BorderRadius.circular(22),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: i == 0
                              ? journeyGreen
                              : const Color(0xfff0eedf),
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: i == 0
                            ? const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                              )
                            : Text('${i + 1}', style: heading(21)),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.lessons[i].title, style: heading(17)),
                            const SizedBox(height: 6),
                            Text(
                              widget.lessons[i].subtitle,
                              style: const TextStyle(
                                color: Color(0xff566b61),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: journeyGreen,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          tr(
            'No rush. Your progress stays with you.',
            'कोई जल्दी नहीं। आपकी प्रगति सुरक्षित है।',
          ),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xff566b61)),
        ),
      ],
    );
  }

  Widget explore() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      section(
        tr('Choose your adventure', 'अपना अभ्यास चुनें'),
        tr(
          'A different way to build your English.',
          'अंग्रेज़ी सीखने के अलग-अलग तरीके।',
        ),
      ),
      tile(
        tr('Word & sentence coach', 'शब्द और वाक्य अभ्यास'),
        tr('Try a sentence. Discover how it works.', 'वाक्य लिखें और समझें।'),
        Icons.auto_fix_high_rounded,
        const Color(0xffebe0fa),
        widget.onGrammar,
      ),
      tile(
        tr('Read out loud', 'ज़ोर से पढ़ें'),
        tr('Practise with the reading coach.', 'पढ़ने के अभ्यास में मदद पाएँ।'),
        Icons.record_voice_over_rounded,
        const Color(0xffffe0ca),
        widget.onReading,
      ),
      tile(
        tr('Find your level', 'अपना स्तर जानें'),
        tr('Short checks for your growing skills.', 'कौशलों के छोटे आकलन।'),
        Icons.explore_rounded,
        journeyLime,
        widget.onCheck,
      ),
      section(
        tr('Your learning team', 'आपकी सीखने की टीम'),
        tr('Support when you need it.', 'ज़रूरत पड़ने पर मदद।'),
      ),
      tile(
        tr('Your school', 'आपका स्कूल'),
        tr(
          'Connect with your teacher and class.',
          'शिक्षक और कक्षा से जुड़ें।',
        ),
        Icons.school_rounded,
        const Color(0xffdfeef8),
        widget.onSchool,
      ),
    ],
  );
  Widget progress() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      section(
        tr('Look how you’re growing', 'देखें आप कितना सीख रहे हैं'),
        tr(
          'Every saved attempt is a step forward.',
          'हर सुरक्षित प्रयास आगे का एक कदम है।',
        ),
      ),
      Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: journeyGreen,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('THIS WEEK', 'इस सप्ताह'),
              style: const TextStyle(
                color: journeyLime,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${widget.weekly}',
              style: const TextStyle(
                fontSize: 54,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            Text(
              tr(
                'saved attempts · ${widget.activeDays} learning days',
                'सुरक्षित प्रयास · ${widget.activeDays} अभ्यास के दिन',
              ),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
      section(
        tr('Your growing skills', 'आपके बढ़ते कौशल'),
        tr(
          'Discover your strengths, one practice at a time.',
          'हर अभ्यास से अपनी ताकत पहचानें।',
        ),
      ),
      for (final skill in widget.skills)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(skill.title, style: heading(18)),
              const SizedBox(height: 8),
              Text(
                skill.detail,
                style: const TextStyle(color: Color(0xff566b61)),
              ),
              if (skill.value != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  label: skill.title,
                  value: '${(skill.value! * 100).round()}%',
                  child: LinearProgressIndicator(
                    value: skill.value,
                    color: journeyGreen,
                    backgroundColor: const Color(0xffeaf0e4),
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ],
            ],
          ),
        ),
      Text(
        tr(
          'Skill estimates use saved answers. Unassessed skills have no score.',
          'कौशल अनुमान सुरक्षित उत्तरों पर आधारित हैं। बिना आकलन कोई स्कोर नहीं।',
        ),
        style: const TextStyle(fontSize: 12, color: Color(0xff566b61)),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: journeyPaper,
    appBar: AppBar(
      backgroundColor: journeyPaper,
      title: const Text(
        'vaachak',
        style: TextStyle(
          fontWeight: FontWeight.w900,
          letterSpacing: -1,
          color: journeyInk,
        ),
      ),
      actions: [
        IconButton(
          tooltip: tr('Privacy', 'गोपनीयता'),
          onPressed: widget.onPrivacy,
          icon: const Icon(Icons.shield_outlined),
        ),
        IconButton(
          tooltip: tr('Lock profile', 'प्रोफ़ाइल लॉक करें'),
          onPressed: widget.onLock,
          icon: const Icon(Icons.lock_outline),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          key: ValueKey('journey-$tab-${widget.age}'),
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 28),
          children: [
            switch (tab) {
              0 => learn(),
              1 => explore(),
              _ => progress(),
            },
          ],
        ),
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (value) => setState(() => tab = value),
      backgroundColor: Colors.white,
      indicatorColor: journeyLime,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.route_outlined),
          selectedIcon: const Icon(Icons.route_rounded),
          label: tr('Learn', 'सीखें'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.widgets_outlined),
          selectedIcon: const Icon(Icons.widgets_rounded),
          label: tr('Explore', 'खोजें'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.insights_outlined),
          selectedIcon: const Icon(Icons.insights_rounded),
          label: tr('Progress', 'प्रगति'),
        ),
      ],
    ),
  );
}
