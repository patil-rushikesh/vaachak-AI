import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'learner_presentation.dart';
import 'content_loader_web.dart'
    if (dart.library.io) 'content_loader_native.dart';
import 'platform_web.dart'
    if (dart.library.io) 'platform_native.dart'
    as platform;

final contentProvider = FutureProvider<ContentBank>((ref) async {
  final data = await Future.wait(
    [
      'skill_graph',
      'grammar_rules',
      'items',
      'passages',
    ].map((n) => rootBundle.loadString('assets/$n.json')),
  );
  return loadInstalledContent(
    ContentBank.decode(data[0], data[1], data[2], passages: data[3]),
  );
});
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: VaachakApp()));
}

class VaachakApp extends ConsumerWidget {
  const VaachakApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'VaachakAI',
    locale: Locale(ref.watch(interfaceLocaleProvider)),
    debugShowCheckedModeBanner: false,
    supportedLocales: const [Locale('en'), Locale('hi')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff205b47)),
      scaffoldBackgroundColor: const Color(0xfff8f7f1),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xfff8f7f1),
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.all(18),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    ),
    home: ref
        .watch(contentProvider)
        .when(
          data: (bank) => platform.PlatformHome(bank: bank),
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (e, s) => const Scaffold(
            body: Center(
              child: Text(
                'The content bank could not be validated. Reinstall a verified build.',
              ),
            ),
          ),
        ),
  );
}
