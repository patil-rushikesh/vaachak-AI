import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../test_support/phase3_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const config = String.fromEnvironment('PHASE3_TEST_CONFIG');
  testWidgets('real Android to PostgREST school round trip', (_) async {
    expect(config, isNotEmpty);
    await checkPhase3(jsonDecode(config) as Map<String, dynamic>);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
