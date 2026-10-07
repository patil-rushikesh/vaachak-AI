import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// On web the recorder returns a blob URL; the path argument is ignored.
Future<String> newRecordingPath(String extension) async => '';

Future<Uint8List> readRecording(String path) async {
  final response = await http.get(Uri.parse(path));
  if (response.statusCode != 200) throw StateError('Recording unavailable');
  return response.bodyBytes;
}

Future<void> deleteRecording(String path) async {}
