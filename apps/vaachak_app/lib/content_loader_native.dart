import 'dart:io';
import 'package:vaachak_content/vaachak_content.dart';
import 'model_runtime.dart';

Future<ContentBank> loadInstalledContent(ContentBank bundled) async {
  ModelRuntime? runtime;
  try {
    runtime = await ModelRuntime.open();
    final installed = (await runtime.installed())
        .where((p) => p.$1.kind == 'content' || p.$1.kind == 'core')
        .toList();
    for (final pack in installed.reversed) {
      final names = ['skill_graph.json', 'grammar_rules.json', 'items.json'];
      if (!names.every((name) => pack.$1.files.any((f) => f['path'] == name))) {
        continue;
      }
      if (pack.$1.files.any((f) => f['path'] == 'passages.json')) {
        names.add('passages.json');
      }
      final strings = <String>[];
      for (final name in names) {
        final file = File('${pack.$2.path}/$name');
        if (await file.length() > 16000000) {
          throw FormatException('Content file exceeds 16 MB');
        }
        strings.add(await file.readAsString());
      }
      final bank = ContentBank.decode(
        strings[0],
        strings[1],
        strings[2],
        passages: strings.length == 4 ? strings[3] : '[]',
      );
      if (!bank.graph.nodes.keys.toSet().containsAll(
            bundled.graph.nodes.keys,
          ) ||
          bank.releaseIssues().isNotEmpty) {
        continue;
      }
      return bank;
    }
  } catch (_) {
    // Unavailable or invalid optional packs never replace the bundled bank.
  } finally {
    await runtime?.packs.dispose();
  }
  return bundled;
}
