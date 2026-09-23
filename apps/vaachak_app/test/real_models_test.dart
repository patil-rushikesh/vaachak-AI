import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/phase2_model_checks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source = Platform.environment['PHASE2_PACK_DIR'];
  test(
    'real signed pack TTS to ASR to encrypted assessment evidence',
    () async {
      await checkPhase2Models(
        source!,
        libraryPath: Platform.environment['SHERPA_LIBRARY_PATH'],
      );
    },
    skip: source == null
        ? 'Set PHASE2_PACK_DIR to a prepared real-model fixture'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
