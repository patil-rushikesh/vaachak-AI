import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/phase3_checks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final path = Platform.environment['PHASE3_CONFIG'];
  test(
    'real PostgREST learner teacher and offline round trip',
    () async {
      await checkPhase3(
        jsonDecode(await File(path!).readAsString()) as Map<String, dynamic>,
      );
    },
    skip: path == null
        ? 'Set PHASE3_CONFIG to local synthetic credentials'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
