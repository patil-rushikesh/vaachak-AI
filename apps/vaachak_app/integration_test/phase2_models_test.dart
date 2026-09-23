import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../test_support/phase2_model_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const source = String.fromEnvironment('PHASE2_PACK_DIR');
  testWidgets(
    'real signed offline speech pack and encrypted evidence on Android',
    (tester) async {
      expect(
        source,
        isNotEmpty,
        reason:
            'Supply --dart-define=PHASE2_PACK_DIR=<device signed test pack path>',
      );
      await checkPhase2Models(source);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
