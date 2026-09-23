import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaachak_explain/vaachak_explain.dart';
import 'package:vaachak_app/explanation_runtime.dart';

class FakeModel implements ExplanationModel {
  int calls = 0, closes = 0;
  final response = Completer<String>();
  @override
  Future<String> generate(String prompt) {
    calls++;
    return response.future;
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

void main() {
  test(
    'activation cancelled during loading closes late native model',
    () async {
      final loaded = Completer<ExplanationModel>();
      final lazy = LazyExplanationModel(load: () => loaded.future);
      final output = lazy.generate('test');
      final expectation = expectLater(output, throwsStateError);
      await lazy.close();
      final model = FakeModel();
      loaded.complete(model);
      await expectation;
      expect(model.closes, 1);
      expect(model.calls, 0);
    },
  );
  test('cancellation during native generation suppresses response', () async {
    final model = FakeModel();
    final lazy = LazyExplanationModel(load: () async => model);
    final output = lazy.generate('test');
    final expectation = expectLater(output, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    await lazy.close();
    model.response.complete('late');
    await expectation;
    expect(model.closes, 1);
    await expectLater(lazy.generate('another'), throwsStateError);
  });
  test('single flight loads once and rejects overlap', () async {
    final model = FakeModel();
    var loads = 0;
    final lazy = LazyExplanationModel(
      load: () async {
        loads++;
        return model;
      },
    );
    final first = lazy.generate('one');
    await expectLater(lazy.generate('two'), throwsStateError);
    model.response.complete('valid');
    expect(await first, 'valid');
    expect(loads, 1);
    await lazy.close();
    await lazy.close();
    expect(model.closes, 1);
  });
}
