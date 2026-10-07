import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vaachak_sync/school_api.dart';

const maxRecordingBytes = 20 * 1024 * 1024;
const maxRecordingSeconds = 300;

class RecordingInfo {
  final String id, language, mime, sha256, path;
  final int durationMs, sizeBytes;
  RecordingInfo(Map<String, dynamic> json)
    : id = json['id'] as String,
      language = json['language'] as String,
      mime = json['mime'] as String,
      sha256 = json['sha256'] as String,
      path = json['path'] as String,
      durationMs = json['durationMs'] as int,
      sizeBytes = (json['sizeBytes'] as num).toInt();
}

/// One teacher recording assigned to a learner's class or to the learner.
class PracticeAssignment {
  final String id, classId, className, learnerId, scope, title;
  final String? instructions;
  final DateTime? dueAt;
  final DateTime createdAt;
  final RecordingInfo recording;
  PracticeAssignment(Map<String, dynamic> json)
    : id = json['id'] as String,
      classId = json['classId'] as String,
      className = json['className'] as String,
      learnerId = json['learnerId'] as String,
      scope = json['scope'] as String,
      title = json['title'] as String,
      instructions = json['instructions'] as String?,
      dueAt = json['dueAt'] == null
          ? null
          : DateTime.parse(json['dueAt'] as String).toLocal(),
      createdAt = DateTime.parse(json['createdAt'] as String).toLocal(),
      recording = RecordingInfo(
        Map<String, dynamic>.from(json['recording'] as Map),
      );
}

/// Teacher upload/assign and learner list/download for lesson recordings.
/// Audio lives in a private bucket; database RPCs enforce who may assign or play.
class LessonRecordingService {
  final SupabaseClient client;
  final SchoolApi api;
  final String environment;
  LessonRecordingService(this.client, this.api, this.environment);
  String get bucket => 'teacher-recordings-$environment';

  static String newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Uploads audio, registers it, then assigns it. A null [learnerId] assigns
  /// the recording to the whole class.
  Future<void> uploadAndAssign({
    required String teacherId,
    required Uint8List bytes,
    required String title,
    required String language,
    required int durationMs,
    required String mime,
    required String extension,
    required String classId,
    String? learnerId,
    String? instructions,
    DateTime? due,
  }) async {
    if (bytes.isEmpty || bytes.length > maxRecordingBytes) {
      throw StateError('Recording is empty or too large');
    }
    final id = newId();
    final path = '$teacherId/$id.$extension';
    await client.storage
        .from(bucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: false),
        );
    try {
      await api.rpc('register_recording', {
        'recording_id': id,
        'recording_title': title,
        'recording_language': language,
        'recording_duration_ms': durationMs,
        'recording_size_bytes': bytes.length,
        'recording_mime': mime,
        'recording_sha256': sha256.convert(bytes).toString(),
        'recording_ext': extension,
      });
    } catch (_) {
      try {
        await client.storage.from(bucket).remove([path]);
      } catch (_) {}
      rethrow;
    }
    await api.rpc('assign_recording', {
      'target_class': classId,
      'target_recording': id,
      'assignment_title': title,
      'assignment_instructions': instructions,
      'assignment_due': due?.toUtc().toIso8601String(),
      'target_learner': learnerId,
    });
  }

  Future<List<PracticeAssignment>> myAssignments() async {
    final result = await api.rpc('my_practice_assignments');
    return (result as List)
        .map((e) => PracticeAssignment(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Downloads and verifies the audio against the registered size and SHA-256.
  Future<Uint8List> download(PracticeAssignment assignment) async {
    final info = assignment.recording;
    final bytes = await client.storage.from(bucket).download(info.path);
    if (bytes.length != info.sizeBytes ||
        sha256.convert(bytes).toString() != info.sha256) {
      throw StateError('Recording failed its integrity check');
    }
    return bytes;
  }
}
