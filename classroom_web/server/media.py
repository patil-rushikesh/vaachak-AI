"""Decode media before accepting it. Bounded ffprobe invocation, no shell."""

import json
import shutil
import subprocess
import tempfile
from fastapi import HTTPException


def validate_audio(data, mime):
    # Signature checks reject mislabeled/nonmedia payloads before invoking a decoder.
    valid = {
        "audio/wav": data[:4] == b"RIFF" and data[8:12] == b"WAVE",
        "audio/x-wav": data[:4] == b"RIFF" and data[8:12] == b"WAVE",
        "audio/webm": data[:4] == b"\x1aE\xdf\xa3",
        "audio/ogg": data[:4] == b"OggS",
        "audio/mp4": data[4:8] == b"ftyp",
        "audio/mpeg": data[:3] == b"ID3"
        or (len(data) > 1 and data[0] == 255 and data[1] & 224 == 224),
        "audio/aac": len(data) > 1 and data[0] == 255 and data[1] & 240 == 240,
    }.get(mime, False)
    if not valid:
        raise HTTPException(415, "Audio content does not match its declared format.")
    probe = shutil.which("ffprobe")
    if not probe:
        raise HTTPException(503, "Media validation service is unavailable.")
    with tempfile.NamedTemporaryFile() as f:
        f.write(data)
        f.flush()
        try:
            result = subprocess.run(
                [
                    probe,
                    "-v",
                    "error",
                    "-protocol_whitelist",
                    "file,pipe",
                    "-show_entries",
                    "stream=codec_type:format=duration",
                    "-of",
                    "json",
                    f.name,
                ],
                capture_output=True,
                timeout=10,
            )
            info = json.loads(result.stdout)
            duration = float(info.get("format", {}).get("duration", 0))
            if (
                result.returncode
                or not any(
                    s.get("codec_type") == "audio" for s in info.get("streams", [])
                )
                or not 0 < duration <= 600
            ):
                raise ValueError()
        except (ValueError, subprocess.TimeoutExpired):
            raise HTTPException(
                415, "Audio could not be decoded or exceeds ten minutes."
            )
