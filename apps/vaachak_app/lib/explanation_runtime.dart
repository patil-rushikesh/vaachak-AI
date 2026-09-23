import 'dart:async';
import 'package:vaachak_explain/vaachak_explain.dart';
import 'model_runtime.dart';

/// Loads only on an explicit learner request; template rendering never waits.
class LazyExplanationModel implements ExplanationModel {
  final Future<ExplanationModel> Function() load;
  ExplanationModel? _model;
  bool _closed = false;
  bool _busy = false;
  LazyExplanationModel({Future<ExplanationModel> Function()? load})
    : load = load ?? (() async => (await ModelRuntime.open()).explainer());

  @override
  Future<String> generate(String prompt) async {
    if (_closed || _busy) throw StateError('Explanation unavailable');
    _busy = true;
    try {
      final model = _model ?? await load();
      if (_closed) {
        await model.close();
        throw StateError('Explanation cancelled');
      }
      _model = model;
      final result = await model.generate(prompt);
      if (_closed) throw StateError('Explanation cancelled');
      return result;
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    final model = _model;
    _model = null;
    await model?.close();
  }
}
