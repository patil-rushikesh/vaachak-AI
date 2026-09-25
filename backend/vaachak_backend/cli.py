"""Local teacher provisioning and reference-analysis commands."""
import argparse
import getpass
import importlib.metadata
import json
import os
import sys
from pathlib import Path

from sqlalchemy import select

from .db import Analysis, Recording, Teacher, connect
from .security import hash_password


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    teacher = commands.add_parser("create-teacher")
    teacher.add_argument("--email", required=True)
    analysis = commands.add_parser("analyze-reference")
    analysis.add_argument("recording_id")
    args = parser.parse_args()
    engine, factory, directory = connect()
    try:
        with factory() as session:
            if args.command == "create-teacher":
                email = args.email.strip().lower()
                if "@" not in email or len(email) > 254:
                    parser.error("Enter a valid email address")
                if session.scalar(select(Teacher).where(Teacher.email == email)):
                    parser.error("Teacher already exists")
                password = getpass.getpass("New password (at least 12 characters): ")
                if not 12 <= len(password) <= 256:
                    parser.error("Use 12–256 characters")
                if password != getpass.getpass("Confirm password: "):
                    parser.error("Passwords do not match")
                record = Teacher(email=email, password_hash=hash_password(password))
                session.add(record)
                session.commit()
                print(f"Created teacher {record.id}")
                return
            recording = session.get(Recording, args.recording_id)
            if recording is None:
                parser.error("Recording not found")
            model_path = os.getenv("VAACHAK_WHISPER_MODEL", "")
            if not model_path or not Path(model_path).is_dir():
                parser.error("Set VAACHAK_WHISPER_MODEL to an installed local faster-whisper model directory")
            try:
                from faster_whisper import WhisperModel
            except ImportError:
                parser.error("Install the optional speech dependencies first: uv sync --extra speech")
            # An immutable run preserves which model files produced the evidence.
            from .audio import digest
            model_files = {p.name: digest(p) for p in Path(model_path).iterdir() if p.is_file()}
            run = Analysis(recording_id=recording.id, model_id=Path(model_path).name)
            session.add(run)
            session.commit()
            try:
                model = WhisperModel(model_path, device="cpu", compute_type="int8", local_files_only=True)
                segments, info = model.transcribe(
                    str(directory / "recordings" / recording.id / "reference.wav"),
                    language="en", word_timestamps=True, vad_filter=True, condition_on_previous_text=False,
                )
                segments = list(segments)
                words = [{"text": w.word.strip(), "start": w.start, "end": w.end,
                          "asr_probability": w.probability}
                         for segment in segments for w in (segment.words or [])]
                text = " ".join(segment.text.strip() for segment in segments).strip()
                if not text:
                    raise ValueError("No speech recognized")
                run.status = "completed"
                run.result = {
                    "transcript": text, "words": words, "language": info.language,
                    "model_files_sha256": model_files,
                    "runtime": f"faster-whisper {importlib.metadata.version('faster-whisper')}",
                    "settings": {"compute_type": "int8", "device": "cpu", "vad_filter": True},
                    "requires_teacher_review": True,
                    "pronunciation_score": None,
                    "note": "ASR timestamps/probabilities are estimates, not calibrated pronunciation scores. Teacher text is unchanged.",
                }
            except Exception:
                run.status = "failed"
                run.result = {"error": "Reference transcription failed; check the local model and audio."}
                session.commit()
                print(json.dumps({"analysis_id": run.id, "status": run.status}), file=sys.stderr)
                raise
            session.commit()
            print(json.dumps({"analysis_id": run.id, "status": run.status}))
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
