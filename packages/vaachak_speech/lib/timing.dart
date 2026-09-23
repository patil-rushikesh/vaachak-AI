import 'package:vaachak_engine/vaachak_engine.dart';
import 'vaachak_speech.dart';

/// Merge actual native token intervals only when English word boundaries are
/// unambiguous. No duration, confidence, or boundary is inferred from text.
/// Unsupported tokenization and incomplete timing degrade to untimed words.
Transcript transcriptFromNative(Map data, String modelId, int durationMs) {
  final text = data['text'] as String? ?? '';
  final words = normaliseWords(text);
  Transcript untimed() =>
      Transcript(words.map((w) => SpokenWord(w, 0, 0)).toList(), modelId);
  final tokens = data['tokens'],
      starts = data['timestamps'],
      lengths = data['durations'];
  if (tokens is! List ||
      starts is! List ||
      lengths is! List ||
      tokens.isEmpty ||
      tokens.length != starts.length ||
      tokens.length != lengths.length) {
    return untimed();
  }
  final merged = <SpokenWord>[];
  var part = '', first = 0, last = 0, previousEnd = 0;
  bool flush() {
    if (part.isEmpty) return true;
    final normalized = normaliseWords(part);
    if (normalized.length != 1 || last <= first) return false;
    merged.add(SpokenWord(normalized.single, first, last));
    part = '';
    return true;
  }

  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i], stamp = starts[i], length = lengths[i];
    if (token is! String ||
        stamp is! num ||
        length is! num ||
        !stamp.isFinite ||
        !length.isFinite ||
        stamp < 0 ||
        length < 0 ||
        !RegExp(r"^[a-zA-Z0-9\s'.,!?;:()\-]+$").hasMatch(token)) {
      return untimed();
    }
    final start = (stamp * 1000).round(),
        end = ((stamp + length) * 1000).round();
    if (start < previousEnd || end > durationMs || end < start) {
      return untimed();
    }
    previousEnd = end;
    final trimmed = token.trim();
    if (trimmed.contains(RegExp(r'\s'))) return untimed();
    if ((token.startsWith(RegExp(r'\s')) || trimmed.isEmpty) && !flush()) {
      return untimed();
    }
    if (RegExp(r'[a-zA-Z0-9]').hasMatch(trimmed)) {
      if (end <= start) return untimed();
      if (part.isEmpty) first = start;
      part += trimmed;
      last = end;
    } else if (trimmed.contains("'")) {
      // Apostrophe fragments can join a lexical piece, but expanded
      // contractions below are intentionally rejected as ambiguous.
      part += trimmed;
    } else if (trimmed.isNotEmpty && !flush()) {
      return untimed();
    }
    if (RegExp(r'\s$').hasMatch(token) && !flush()) return untimed();
  }
  if (!flush() || merged.length != words.length) return untimed();
  for (var i = 0; i < words.length; i++) {
    if (merged[i].text != words[i]) return untimed();
  }
  return Transcript(
    List.unmodifiable(merged),
    modelId,
    hasWordTiming: merged.isNotEmpty,
  );
}
