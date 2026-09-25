# Offline speech boundaries

The Sherpa adapter runs Whisper/Zipformer ASR and Piper/VITS TTS in a worker isolate. Only one native recognizer or voice is resident in that worker. Disposal cancels Dart result delivery immediately, then queues native cleanup; the model lease is released after worker exit. Synchronous native inference is not forcibly interrupted.

Whisper recordings are capped at 29 seconds. The pinned upstream v1.13.8 implementation discards input beyond approximately 29.5 seconds, so accepting longer recordings would produce invalid whole-recording accuracy and pace results. Other supported recognizers retain the 60-second application cap.

Whisper token and segment timing are requested. Older model exports without cross-attention outputs still transcribe, but cannot provide token timing. The adapter reads actual token durations through the documented C JSON API because the pinned Dart result wrapper omits that field. Every native JSON allocation is freed after copying.

The conservative English token merger requires complete, finite, ordered intervals inside the captured duration, unambiguous word boundaries, and exact agreement with normalized decoded text. Unsupported tokenization, expanded contractions, missing durations, and zero-length lexical tokens fall back to untimed words. Word-end times and confidence values are never fabricated. `hasWordTiming` indicates available model-estimated intervals, not calibration against human annotations. The existing reading aligner can classify hesitation only when these intervals are available. ASR text differences are not acoustic pronunciation diagnoses.

Signal quality is a heuristic gate using level, clipping, duration, and frame-energy variation; its `snrDb` metric is an energy-quantile proxy rather than a calibrated acoustic SNR measurement. Synthetic tests validate implementation behavior, not recognition quality or accent fairness.

Upstream references:

- [Native Whisper limit and token-duration output](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/sherpa-onnx/csrc/offline-recognizer-whisper-impl.h)
- [Attention-output requirement and timing fallback](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/sherpa-onnx/csrc/offline-whisper-greedy-search-decoder.cc)
- [C API](https://k2-fsa.github.io/sherpa/onnx/c-api/index.html)
