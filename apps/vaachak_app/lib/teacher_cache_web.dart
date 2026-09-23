// The browser portal is online-only; never leave learner rosters in web storage.
Future<Map<String, dynamic>?> readTeacherCache(String scope) async => null;
Future<void> writeTeacherCache(String scope, Map<String, dynamic> data) async {}
Future<void> clearTeacherCache(String scope) async {}
