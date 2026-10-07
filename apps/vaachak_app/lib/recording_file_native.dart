import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Temporary file for an in-progress teacher recording (native platforms).
Future<String> newRecordingPath(String extension) async {
  final dir = await getTemporaryDirectory();
  return '${dir.path}/lesson_${DateTime.now().microsecondsSinceEpoch}.$extension';
}

Future<Uint8List> readRecording(String path) => File(path).readAsBytes();

Future<void> deleteRecording(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best effort: the OS clears the temporary directory.
  }
}
