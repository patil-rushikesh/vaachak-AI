import 'dart:async';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'vaachak_explain.dart';

class GemmaExplanationModel implements ExplanationModel {
  InferenceModel? _model;
  Timer? _idle;
  int _generation = 0;
  bool _busy = false;
  bool _initialized = false;
  bool _closed = false;
  final String verifiedModelPath;
  GemmaExplanationModel(this.verifiedModelPath);
  Future<void> initialize() async {
    if (_closed || _initialized) {
      throw StateError('Invalid explainer lifecycle');
    }
    await FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()]);
    await FlutterGemma.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    ).fromFile(verifiedModelPath).install();
    if (_closed) throw StateError('Explainer activation cancelled');
    _initialized = true;
  }

  @override
  Future<String> generate(String prompt) async {
    if (_closed || !_initialized || _busy) {
      throw StateError('Explanation inference is already running');
    }
    _busy = true;
    _idle?.cancel();
    final ticket = _generation;
    try {
      final model =
          _model ??
          await FlutterGemma.getActiveModel(
            maxTokens: 1024,
            preferredBackend: PreferredBackend.cpu,
          );
      if (ticket != _generation) {
        await model.close();
        throw StateError('Explanation request was cancelled');
      }
      _model = model;
      final chat = await model.createChat(
        maxOutputTokens: 160,
        temperature: 0.1,
      );
      try {
        await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
        final response = await chat.generateChatResponse();
        if (ticket != _generation || response is! TextResponse) {
          throw StateError('No usable model response');
        }
        return response.token;
      } finally {
        await chat.session.close();
      }
    } finally {
      _busy = false;
      if (!_closed && _model != null) {
        _idle = Timer(const Duration(seconds: 90), () {
          unawaited(close().catchError((Object _) {}));
        });
      }
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _generation++;
    _idle?.cancel();
    final current = _model;
    _model = null;
    await current?.close();
  }
}
