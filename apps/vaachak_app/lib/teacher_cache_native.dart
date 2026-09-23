import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

Future<Map<String, dynamic>?> readTeacherCache(String scope) async {
  final raw = await const FlutterSecureStorage().read(
    key: 'teacher.roster:$scope',
  );
  if (raw == null) return null;
  final data = jsonDecode(raw) as Map<String, dynamic>;
  final at = DateTime.parse(data['cachedAt'] as String);
  if (DateTime.now().difference(at) > const Duration(hours: 24)) {
    await clearTeacherCache(scope);
    return null;
  }
  return data;
}

Future<void> writeTeacherCache(String scope, Map<String, dynamic> data) async {
  final raw = jsonEncode({
    ...data,
    'cachedAt': DateTime.now().toUtc().toIso8601String(),
  });
  if (utf8.encode(raw).length > 1024 * 1024) {
    await clearTeacherCache(scope);
    return;
  }
  await const FlutterSecureStorage().write(
    key: 'teacher.roster:$scope',
    value: raw,
  );
}

Future<void> clearTeacherCache(String scope) =>
    const FlutterSecureStorage().delete(key: 'teacher.roster:$scope');
