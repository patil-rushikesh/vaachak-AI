import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaachak_app/journey_dashboard.dart';

void main() {
  JourneyDashboard dashboard({
    String locale = 'en',
    VoidCallback? start,
    VoidCallback? coach,
    bool empty = false,
  }) => JourneyDashboard(
    name: 'Riya',
    locale: locale,
    age: 'child',
    today: 1,
    weekly: 12,
    activeDays: 3,
    lessons: empty
        ? []
        : [
            JourneyLesson(
              'Everyday words',
              'Vocabulary · 5 questions',
              start ?? () {},
            ),
            JourneyLesson('Build a sentence', 'Sentences · 3 questions', () {}),
          ],
    skills: const [
      JourneySkill('Vocabulary', 'Building confidence · 12 saved attempts', .6),
      JourneySkill('Reading', 'Ready to discover', null),
    ],
    onReading: coach ?? () {},
    onGrammar: () {},
    onCheck: start ?? () {},
    onSchool: () {},
    onPrivacy: () {},
    onLock: () {},
  );
  testWidgets('one primary start, functional tabs and coach route', (
    tester,
  ) async {
    var starts = 0, coaches = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: dashboard(start: () => starts++, coach: () => coaches++),
      ),
    );
    await tester.tap(find.text('Start learning'));
    await tester.pump();
    expect(starts, 1);
    await tester.tap(find.text('Explore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read out loud'));
    expect(coaches, 1);
    await tester.tap(find.text('Progress'));
    await tester.pumpAndSettle();
    expect(find.text('12'), findsOneWidget);
    await tester.tap(find.text('Learn'));
    await tester.pumpAndSettle();
    expect(find.text('Start learning'), findsOneWidget);
  });
  for (final language in ['en', 'hi']) {
    testWidgets('narrow screen and large text: $language', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: dashboard(locale: language),
        ),
      );
      for (final label
          in language == 'hi'
              ? ['खोजें', 'प्रगति', 'सीखें']
              : ['Explore', 'Progress', 'Learn']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
  testWidgets('empty path has a working next action', (tester) async {
    var checks = 0;
    await tester.pumpWidget(
      MaterialApp(home: dashboard(empty: true, start: () => checks++)),
    );
    expect(find.text('Start learning'), findsNothing);
    await tester.tap(find.text('Find an activity'));
    expect(checks, 1);
  });
  testWidgets('render learner dashboard preview', (tester) async {
    const fontPath = '/System/Library/Fonts/Supplemental/Arial.ttf';
    if (!File(fontPath).existsSync()) return;
    final fonts = FontLoader('Preview');
    fonts.addFont(
      Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())),
    );
    await fonts.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(
      Future.value(
        ByteData.sublistView(
          File(
            '/Users/admin/.local/share/vaachak/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytesSync(),
        ),
      ),
    );
    await icons.load();
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'Preview',
            colorScheme: ColorScheme.fromSeed(seedColor: journeyGreen),
          ),
          home: dashboard(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        '/Users/admin/genai/build/share/vaachak-redesign-preview.png',
      );
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
