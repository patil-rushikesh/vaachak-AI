"""Audio preparation. Energy gaps are measurements, not linguistic judgments."""
import hashlib
import json
import shutil
import subprocess
import wave
from pathlib import Path

import numpy as np

MAX_BYTES = 20 * 1024 * 1024
MAX_SECONDS = 120


class InvalidAudio(ValueError):
    pass


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def normalize(source: Path, target: Path):
    if not shutil.which("ffmpeg"):
        raise RuntimeError("FFmpeg must be installed before uploading audio")
    # Ignore client filenames. Decode only local, single-file media containers;
    # disallow playlists/network protocols and cap decoder time/output duration.
    command = [
        "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-y", "-threads", "1",
        "-protocol_whitelist", "file,pipe",
        "-format_whitelist", "wav,mp3,mov,matroska,webm,ogg,flac,aac,aiff",
        "-i", str(source), "-map", "0:a:0", "-vn", "-t", str(MAX_SECONDS + 1),
        "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(target),
    ]
    try:
        subprocess.run(command, capture_output=True, check=True, timeout=30)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise InvalidAudio("Unable to decode audio; upload WAV, MP3, M4A, WebM, Ogg or FLAC") from exc
    source_metadata = {}
    if shutil.which("ffprobe"):
        try:
            probe = subprocess.run([
                "ffprobe", "-v", "error", "-protocol_whitelist", "file,pipe",
                "-format_whitelist", "wav,mp3,mov,matroska,webm,ogg,flac,aac,aiff",
                "-select_streams", "a:0", "-show_entries",
                "stream=codec_name,sample_rate,channels,bits_per_sample,duration:format=format_name",
                "-of", "json", str(source),
            ], capture_output=True, check=True, timeout=10)
            metadata = json.loads(probe.stdout)
            source_metadata = {**metadata.get("streams", [{}])[0],
                               "container": metadata.get("format", {}).get("format_name")}
        except (subprocess.SubprocessError, ValueError, IndexError):
            # Preserve audio even if metadata probing is unavailable; never invent its format.
            source_metadata = {"status": "unavailable"}
    with wave.open(str(target), "rb") as stream:
        samples = np.frombuffer(stream.readframes(stream.getnframes()), dtype="<i2").astype(np.float64) / 32768
    duration = len(samples) / 16000
    if not 0.5 <= duration <= MAX_SECONDS:
        raise InvalidAudio("Recording must be between 0.5 and 120 seconds")
    peak = float(np.max(np.abs(samples)))
    rms = float(np.sqrt(np.mean(samples ** 2)))
    if peak < 0.001 or rms < 0.0001:
        raise InvalidAudio("Recording is silent or too quiet; please record again")
    # 20 ms RMS windows; preserve original pauses, pitch and speed.
    frames = samples[:len(samples) // 320 * 320].reshape(-1, 320)
    energies = np.sqrt(np.mean(frames ** 2, axis=1))
    threshold = max(0.003, float(np.percentile(energies, 90)) * 0.12)
    quiet = energies < threshold
    gaps, start = [], None
    for index, is_quiet in enumerate([*quiet, False]):
        if is_quiet and start is None:
            start = index
        elif not is_quiet and start is not None:
            if (index - start) * 0.02 >= 0.15:
                gaps.append({"start": round(start * 0.02, 3), "end": round(index * 0.02, 3)})
            start = None
    return {
        "measurement_version": "energy-v1",
        "sample_rate": 16000, "channels": 1, "sample_format": "PCM_S16LE",
        "duration_seconds": duration, "peak": peak, "rms": rms,
        "clipped_sample_fraction": float(np.mean(np.abs(samples) >= 0.999)),
        "low_energy_intervals": gaps, "energy_threshold": threshold,
        "interpretation": "Low energy is not verified silence, speech detection or a punctuation error.",
        "pronunciation_score": None,
        "source_media": source_metadata,
        "preservation": {
            "original": "byte_for_byte",
            "processing": "resample_and_downmix_only",
            "pitch_analysis": "not_run",
            "pause_trimming": False,
        },
    }
