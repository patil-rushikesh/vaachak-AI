"""Signal-processing checks, not validation of child-speech or emotion grading."""

import json
import wave

import numpy as np
import pytest

from vaachak_backend.prosody import analyze_pitch, compare_pitch


def audio_file(tmp_path, signal, name="pitch.wav", rate=16000):
    path = tmp_path / name
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes((np.clip(signal, -1, 1) * 32767).astype("<i2").tobytes())
    return path


def sine(frequency, seconds=2, amplitude=0.3):
    t = np.arange(round(seconds * 16000)) / 16000
    return amplitude * np.sin(2 * np.pi * frequency * t)


@pytest.mark.parametrize("frequency", [80, 110, 220, 440, 600])
def test_sine_fundamental_and_unchanged_waveform(tmp_path, frequency):
    path = audio_file(tmp_path, sine(frequency))
    before = path.read_bytes()
    result = analyze_pitch(path)
    assert path.read_bytes() == before
    assert result["status"] == "available"
    assert result["summary"]["median_f0_hz"] == pytest.approx(frequency, rel=0.005)
    assert result["summary"]["voiced_fraction"] > 0.95
    assert result["summary"]["range_semitones"] < 0.05
    assert result["score"] is None
    assert all(frame["confidence"] > 0.95 for frame in result["frames"])
    json.dumps(result, allow_nan=False)


def test_harmonic_voice_like_wave_keeps_fundamental(tmp_path):
    signal = sine(160, amplitude=0.1) + sine(320, amplitude=0.16) + sine(480, amplitude=0.09)
    result = analyze_pitch(audio_file(tmp_path, signal))
    assert result["status"] == "available"
    assert result["summary"]["median_f0_hz"] == pytest.approx(160, rel=0.01)


def test_rising_chirp_produces_a_rising_contour(tmp_path):
    time = np.arange(4 * 16000) / 16000
    signal = 0.3 * np.sin(2 * np.pi * (120 * time + 0.5 * 40 * time ** 2))
    result = analyze_pitch(audio_file(tmp_path, signal))
    assert result["status"] == "available"
    voiced = [frame for frame in result["frames"] if frame["voiced"]]
    errors = [abs(frame["f0_hz"] - (120 + 40 * frame["time_seconds"])) / (120 + 40 * frame["time_seconds"]) for frame in voiced]
    assert np.median(errors) < 0.015
    assert voiced[0]["relative_semitones"] < -4
    assert voiced[-1]["relative_semitones"] > 4
    assert result["summary"]["range_semitones"] > 10


@pytest.mark.parametrize("signal", [np.zeros(32000), np.full(32000, 0.3),
                                    np.random.default_rng(123).normal(0, 0.2, 32000),
                                    sine(40), sine(1000)])
def test_silence_dc_noise_and_out_of_range_tones_are_not_pitch_grades(tmp_path, signal):
    result = analyze_pitch(audio_file(tmp_path, signal))
    assert result["status"] == "insufficient_evidence"
    assert result["summary"]["median_f0_hz"] is None
    assert result["score"] is None
    assert result["summary"]["voiced_fraction"] < 0.1
    assert all(frame["relative_semitones"] is None for frame in result["frames"])
    json.dumps(result, allow_nan=False)


def test_moderate_noise_retains_supported_pitch(tmp_path):
    signal = sine(220) + np.random.default_rng(42).normal(0, 0.025, 32000)
    result = analyze_pitch(audio_file(tmp_path, signal))
    assert result["status"] == "available"
    assert result["summary"]["median_f0_hz"] == pytest.approx(220, rel=0.015)
    assert result["summary"]["voiced_fraction"] > 0.9


def test_voiced_and_unvoiced_intervals_keep_their_timestamps(tmp_path):
    signal = np.concatenate([np.zeros(16000), sine(180, seconds=1), np.zeros(16000)])
    result = analyze_pitch(audio_file(tmp_path, signal))
    assert result["status"] == "available"
    frames = result["frames"]
    assert all(not frame["voiced"] for frame in frames if frame["time_seconds"] < 0.95 or frame["time_seconds"] > 2.05)
    assert all(frame["voiced"] for frame in frames if 1.1 < frame["time_seconds"] < 1.9)
    assert 0.25 < result["summary"]["voiced_fraction"] < 0.4


def test_maximum_recording_has_bounded_json_and_explicit_sampling(tmp_path):
    result = analyze_pitch(audio_file(tmp_path, sine(220, seconds=120)))
    assert result["status"] == "available"
    assert len(result["frames"]) <= 1000
    assert 5900 < result["analyzed_frame_count"] <= 6000
    assert result["display_frame_count"] == len(result["frames"])
    assert result["frame_hop_seconds"] == 0.02
    assert result["track_step_seconds"] > result["frame_hop_seconds"]
    encoded = json.dumps(result, allow_nan=False)
    assert "full_frames" not in encoded
    assert len(encoded) < 200000


@pytest.mark.parametrize("seconds", [0.1, 120.1])
def test_invalid_duration_is_unavailable(tmp_path, seconds):
    result = analyze_pitch(audio_file(tmp_path, sine(200, seconds=seconds)))
    assert result["status"] == "unavailable" and result["frames"] == []


def test_missing_and_non_normalized_audio_are_unavailable(tmp_path):
    assert analyze_pitch(tmp_path / "missing.wav")["status"] == "unavailable"
    path = audio_file(tmp_path, sine(200), rate=48000)
    assert analyze_pitch(path)["status"] == "unavailable"


def words_and_alignment():
    words = [{"word": word, "start": 0.1 + i * 0.45, "end": 0.45 + i * 0.45}
             for i, word in enumerate(["this", "is", "my", "home"])]
    alignment = [{"operation": "match", "expected_index": i, "spoken_index": i,
                  "expected": word["word"], "spoken": word["word"]} for i, word in enumerate(words)]
    return words, alignment


def test_relative_comparison_does_not_penalize_different_voice_registers(tmp_path):
    student = analyze_pitch(audio_file(tmp_path, sine(240), name="student.wav"))
    teacher = analyze_pitch(audio_file(tmp_path, sine(120), name="teacher.wav"))
    words, alignment = words_and_alignment()
    result = compare_pitch(student, teacher, words, words, alignment, alignment)
    assert result["status"] == "available"
    assert len(result["points"]) == 4
    assert result["median_absolute_difference_semitones"] < 0.05
    assert "score" not in result
    assert "mood" not in result and "emotion" not in result


def test_relative_comparison_requires_matching_words_and_voiced_evidence(tmp_path):
    student = analyze_pitch(audio_file(tmp_path, sine(240), name="student.wav"))
    teacher = analyze_pitch(audio_file(tmp_path, sine(120), name="teacher.wav"))
    words, alignment = words_and_alignment()
    wrong = [dict(item, operation="substitution") for item in alignment]
    result = compare_pitch(student, teacher, words, words, wrong, alignment)
    assert result["status"] == "insufficient_evidence"
    assert result["median_absolute_difference_semitones"] is None
    quiet = analyze_pitch(audio_file(tmp_path, np.zeros(32000), name="quiet.wav"))
    assert compare_pitch(student, quiet, words, words, alignment, alignment)["status"] == "insufficient_evidence"
