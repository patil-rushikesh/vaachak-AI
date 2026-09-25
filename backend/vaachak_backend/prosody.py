"""Bounded, experimental pitch evidence, separate from learning grades.

This is a YIN-style cumulative-mean-normalized difference estimator, not pYIN
or a trained speech/voicing classifier. Its confidence measures periodicity;
it is not a calibrated probability. Tones/music may also be periodic.
Original recordings are never changed. Reference comparisons center each
speaker on their own median and use matching ASR word intervals.
"""

from __future__ import annotations

import math
import wave
from pathlib import Path

import numpy as np

ALGORITHM_VERSION = "yin-cmndf-v1"
SAMPLE_RATE = 16000
HOP = 320
FMIN = 65.0
FMAX = 650.0
THRESHOLD = 0.15
WINDOW = 640
MAX_LAG = math.ceil(SAMPLE_RATE / FMIN)
FRAME_LENGTH = WINDOW + MAX_LAG
BATCH_SIZE = 128
_LIMITATIONS = (
    "Experimental periodicity-based pitch estimates, not a pitch accuracy or pronunciation grade. "
    "Noise, music, breathy/irregular voice, octave errors and frequencies outside 65–650 Hz can affect results. "
    "Confidence is periodicity strength, not calibrated voicing probability. Emotion and mood are not inferred."
)


class _PitchEvidence(dict):
    # Internal full-resolution evidence is an attribute, never a JSON key.
    # HTTP/database JSON contains at most 1000 display frames. Word comparison
    # within this analysis job uses the complete 20 ms track before serialization.
    full_frames: list[dict]


def _base(status="unavailable") -> dict:
    return {
        "status": status, "algorithm_version": ALGORITHM_VERSION, "experimental": True,
        "score": None, "frame_hop_seconds": HOP / SAMPLE_RATE,
        "window_seconds": FRAME_LENGTH / SAMPLE_RATE,
        "frequency_range_hz": [FMIN, FMAX], "confidence_kind": "periodicity_not_probability",
        "frames": [], "summary": {"median_f0_hz": None, "voiced_fraction": 0.0,
                                    "voiced_seconds": 0.0, "range_semitones": None},
        "interpretation": _LIMITATIONS,
    }


def _read_samples(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as audio:
        if (audio.getframerate() != SAMPLE_RATE or audio.getnchannels() != 1
                or audio.getsampwidth() != 2 or not SAMPLE_RATE / 2 <= audio.getnframes() <= SAMPLE_RATE * 120):
            raise ValueError("Pitch analysis requires a 0.5–120 second normalized mono 16 kHz PCM16 WAV")
        count = audio.getnframes()
        raw = audio.readframes(count)
    if len(raw) != count * 2:
        raise ValueError("Truncated analysis audio")
    return np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0


def _difference(batch: np.ndarray) -> np.ndarray:
    """YIN difference with the same 40 ms integration length at every lag."""
    size = 1 << ((FRAME_LENGTH + WINDOW - 2).bit_length())
    original_fft = np.fft.rfft(batch, n=size, axis=1)
    base_fft = np.fft.rfft(batch[:, :WINDOW], n=size, axis=1)
    correlation = np.fft.irfft(original_fft * base_fft.conj(), n=size, axis=1)[:, :MAX_LAG + 1]
    cumulative = np.pad(np.cumsum(batch * batch, axis=1), ((0, 0), (1, 0)))
    shifted_energy = cumulative[:, WINDOW:WINDOW + MAX_LAG + 1] - cumulative[:, :MAX_LAG + 1]
    base_energy = cumulative[:, WINDOW, None]
    difference = np.maximum(0.0, base_energy + shifted_energy - 2 * correlation)
    sums = np.cumsum(difference[:, 1:], axis=1)
    normalized = np.ones_like(difference)
    np.divide(difference[:, 1:] * np.arange(1, MAX_LAG + 1), sums,
              out=normalized[:, 1:], where=sums > 1e-12)
    return normalized


def _pitch_for_frame(curve: np.ndarray) -> tuple[float | None, float]:
    # Search from the smallest lags first, including above FMAX. Otherwise a
    # 1000 Hz tone can incorrectly be accepted as its 500 Hz subharmonic.
    candidates = np.flatnonzero(curve[2:] < THRESHOLD) + 2
    if not len(candidates):
        return None, round(float(max(0.0, 1.0 - np.min(curve[2:]))), 4)
    lag = int(candidates[0])
    while lag < MAX_LAG and curve[lag + 1] < curve[lag]:
        lag += 1
    refined = float(lag)
    if 1 < lag < MAX_LAG:
        left, center, right = curve[lag - 1], curve[lag], curve[lag + 1]
        denominator = left - 2 * center + right
        if denominator > 1e-12:
            refined += float(np.clip((left - right) / (2 * denominator), -0.5, 0.5))
    frequency = SAMPLE_RATE / refined
    confidence = round(float(np.clip(1 - curve[lag], 0.0, 1.0)), 4)
    if not FMIN <= frequency <= FMAX:
        return None, confidence
    return round(frequency, 2), confidence


def analyze_pitch(path) -> dict:
    """Read normalized audio and return timestamped F0/voicing evidence safely."""
    result = _PitchEvidence(_base())
    result.full_frames = []
    try:
        samples = _read_samples(Path(path))
        starts = np.arange(0, len(samples) - FRAME_LENGTH + 1, HOP)
        # Sliding windows are a view; only a small batch is copied for FFTs.
        windows = np.lib.stride_tricks.sliding_window_view(samples, FRAME_LENGTH)[::HOP]
        rms = np.sqrt(np.mean(windows[:, ::4] ** 2, axis=1))
        energy_threshold = max(0.003, float(np.percentile(rms, 90)) * 0.08)
        frames = []
        for offset in range(0, len(starts), BATCH_SIZE):
            batch = np.array(windows[offset:offset + BATCH_SIZE], copy=True)
            batch -= batch.mean(axis=1, keepdims=True)
            curves = _difference(batch)
            for local, curve in enumerate(curves):
                index = offset + local
                frequency, confidence = _pitch_for_frame(curve) if rms[index] >= energy_threshold else (None, 0.0)
                frames.append({"time_seconds": round(float((starts[index] + FRAME_LENGTH / 2) / SAMPLE_RATE), 4),
                               "f0_hz": frequency, "voiced": frequency is not None,
                               "confidence": confidence, "relative_semitones": None})
        voiced = [frame for frame in frames if frame["voiced"]]
        coverage = len(voiced) / len(frames) if frames else 0.0
        result.full_frames = frames
        step = max(1, math.ceil(len(frames) / 1000))
        result["frames"] = frames[::step]
        result["track_step_seconds"] = round(step * HOP / SAMPLE_RATE, 3)
        result["analyzed_frame_count"] = len(frames)
        result["display_frame_count"] = len(result["frames"])
        result["duration_seconds"] = round(len(samples) / SAMPLE_RATE, 3)
        result["summary"].update({"voiced_fraction": round(coverage, 4),
                                   "voiced_seconds": round(len(voiced) * HOP / SAMPLE_RATE, 3)})
        if len(voiced) < 10 or coverage < 0.1:
            result["status"] = "insufficient_evidence"
            result["reason"] = "Too little reliable periodic voice was detected for a pitch contour."
            return result
        median = float(np.median([frame["f0_hz"] for frame in voiced]))
        for frame in voiced:
            frame["relative_semitones"] = round(12 * math.log2(frame["f0_hz"] / median), 3)
        relative = [frame["relative_semitones"] for frame in voiced]
        result["status"] = "available"
        result["summary"].update({"median_f0_hz": round(median, 2),
                                   "range_semitones": round(float(np.percentile(relative, 95) - np.percentile(relative, 5)), 3)})
        return result
    except (OSError, ValueError, wave.Error, EOFError):
        result["reason"] = "Pitch evidence could not be read from the normalized audio."
        return result


def compare_pitch(student_pitch, reference_pitch, student_words, reference_words,
                  student_alignment, reference_alignment) -> dict:
    """Compare matching words after centering each speaker on their own median."""
    result = {
        "status": "insufficient_evidence", "method": "word_aligned_speaker_centered_contour",
        "points": [], "median_absolute_difference_semitones": None,
        "interpretation": "Each voice is centered on its own median pitch. Word-level relative differences are experimental practice evidence, not a correctness or emotion score.",
    }
    if student_pitch.get("status") != "available" or reference_pitch.get("status") != "available":
        result["reason"] = "Both recordings need reliable voiced pitch evidence."
        return result
    student_map = {item["expected_index"]: item["spoken_index"] for item in student_alignment if item["operation"] == "match"}
    reference_map = {item["expected_index"]: item["spoken_index"] for item in reference_alignment if item["operation"] == "match"}
    expected_words = {item["expected_index"]: item["expected"] for item in student_alignment if item["operation"] == "match"}

    def summarize(pitch, word):
        start, end = word.get("start"), word.get("end")
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in (start, end)) or end <= start:
            return None
        source_frames = getattr(pitch, "full_frames", pitch["frames"])
        frames = [frame for frame in source_frames if start <= frame["time_seconds"] <= end]
        reliable = [frame["relative_semitones"] for frame in frames if frame["voiced"] and frame["relative_semitones"] is not None]
        if len(reliable) < 3 or len(reliable) / max(1, len(frames)) < 0.25:
            return None
        return round(float(np.median(reliable)), 3)

    for index in sorted(student_map.keys() & reference_map.keys()):
        s, r = student_map[index], reference_map[index]
        if not 0 <= s < len(student_words) or not 0 <= r < len(reference_words):
            continue
        student_value = summarize(student_pitch, student_words[s])
        reference_value = summarize(reference_pitch, reference_words[r])
        if student_value is None or reference_value is None:
            continue
        result["points"].append({"word": expected_words[index], "expected_word_index": index,
                                 "student_semitones": student_value, "reference_semitones": reference_value,
                                 "difference_semitones": round(student_value - reference_value, 3)})
    if len(result["points"]) < 3:
        result["reason"] = "At least three matching words with voiced evidence are needed for contour comparison."
        return result
    result["status"] = "available"
    result["median_absolute_difference_semitones"] = round(float(np.median([abs(point["difference_semitones"]) for point in result["points"]])), 3)
    return result
