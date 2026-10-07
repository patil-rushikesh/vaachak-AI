"""Check that the AI actually works on this computer.

    python check_ai.py                 check the key, the models, and a real coaching call
    python check_ai.py some_voice.m4a  also send a real recording through speech-to-text

Nothing here changes your data. It only talks to Groq and prints what happened.
"""
from __future__ import annotations

import json
import sys
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "server"))

import ai  # noqa: E402

OK, BAD, INFO = "[ok]", "[!!]", "   -"


def fail(msg: str, *fixes: str) -> None:
    print(f"\n{BAD} {msg}")
    for f in fixes:
        print(f"{INFO} {f}")
    sys.exit(1)


def main() -> None:
    ai.load_env_file()
    print("Checking the AI setup for Vaachak Classroom\n" + "-" * 44)

    key = ai.api_key()
    if not key:
        fail("No API key found.",
             "Put your key in the file vaachak.env next to this script, as one line:",
             "GROQ_API_KEY=gsk_your_key_here",
             "Then run this check again.")
    print(f"{OK} Key found: {key[:7]}...{key[-4:]} (from vaachak.env or the environment)")

    # 1. Is the key accepted at all, and what can it use?
    try:
        with ai._client(20.0) as c:
            r = c.get(f"{ai.BASE}/models", headers={"Authorization": f"Bearer {key}"})
    except Exception as e:
        fail(f"Could not reach Groq: {type(e).__name__}: {e}",
             "Check your internet connection.",
             "If you are on college wifi or a VPN, it may be blocking api.groq.com.")
    if r.status_code in (401, 403):
        fail("Groq rejected the key.",
             "The key may be wrong, revoked, or copied with a missing character.",
             "Make a new one at https://console.groq.com/keys and put it in vaachak.env.")
    if r.status_code != 200:
        fail(f"Groq answered with HTTP {r.status_code}: {r.text[:200]}")

    available = sorted(m["id"] for m in r.json().get("data", []))
    print(f"{OK} Key works. {len(available)} models available to you.")

    asr_here = [m for m in available if "whisper" in m]
    chat_here = [m for m in available if any(w in m for w in ("llama", "gpt", "qwen", "gemma", "kimi"))]
    print(f"{INFO} speech-to-text: {', '.join(asr_here) or 'none found'}")
    print(f"{INFO} chat: {', '.join(chat_here[:8]) or 'none found'}")

    # 2. Does the model this app will actually pick still exist?
    for kind, found in (("asr", asr_here), ("chat", chat_here)):
        wanted = ai._models(kind)
        if not any(w in available for w in wanted):
            label = "speech-to-text" if kind == "asr" else "feedback"
            env = "VAACHAK_ASR_MODEL" if kind == "asr" else "VAACHAK_CHAT_MODEL"
            fail(f"None of the {label} models this app knows about are available to you.",
                 f"The app would try: {', '.join(wanted)}",
                 f"Your account has: {', '.join(found[:6]) or 'none'}",
                 f"Add a line to vaachak.env: {env}=<one of yours above>")
        picked = next(w for w in wanted if w in available)
        print(f"{OK} Will use for {'speech-to-text' if kind == 'asr' else 'feedback'}: {picked}")

    # 3. A real coaching call, end to end.
    print("\nAsking the model to coach a learner who said: \"he like music and she don't play\"")
    out = ai.coach("free", None, "he like music and she don't play", prompt="Tell us about your family.")
    if not out:
        fail("The feedback call did not work.",
             "Scroll up: the reason was printed as a warning.",
             "If it says HTTP 429, you have hit the free rate limit. Wait a minute and retry.")
    print(f"{OK} Feedback came back.")
    print(f"{INFO} score: {out['score']}")
    print(f"{INFO} verdict: {out['verdict']}")
    for c in out["grammar"]:
        print(f"{INFO} fix: \"{c['said']}\" -> \"{c['fix']}\" ({c['skill']}) {c['why']}")
    print(f"{INFO} say next: {out['next_line']}")
    if not out["grammar"]:
        print(f"{BAD} It found no mistakes in a sentence that has two. The model may be weak;")
        print(f"{INFO} try a bigger one, e.g. add VAACHAK_CHAT_MODEL=llama-3.3-70b-versatile to vaachak.env")

    # 4. Speech to text, with a real recording if one was given.
    path = sys.argv[1] if len(sys.argv) > 1 else None
    if path:
        if not Path(path).exists():
            fail(f"No such file: {path}")
        print(f"\nSending {path} to speech-to-text...")
        text = ai.transcribe(path, "audio/" + Path(path).suffix.lstrip("."))
        if text:
            print(f"{OK} It heard: \"{text}\"")
        else:
            fail("Speech-to-text returned nothing.",
                 "Check the warning printed above.",
                 "Make sure the file really contains speech and is under 20 MB.")
    else:
        tmp = Path("_check_tone.wav")
        with wave.open(str(tmp), "wb") as w:  # a valid, silent wav just to prove the endpoint works
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(b"\x00\x00" * 16000)
        try:
            ai.transcribe(str(tmp), "audio/wav")
            print(f"\n{OK} Speech-to-text accepted a test file (silent, so no words came back).")
            print(f"{INFO} To test it properly: python check_ai.py path\\to\\a\\real\\recording.m4a")
        finally:
            tmp.unlink(missing_ok=True)

    print("\n" + "-" * 44)
    print("All good. Start the app and the AI feedback will be live.")


if __name__ == "__main__":
    main()
