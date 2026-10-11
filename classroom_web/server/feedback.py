"""Speech and writing feedback: grammar, word-level pronunciation, sentence building.

Everything here is deterministic and runs offline.

Pronunciation is *inferred from what the speech recogniser heard*. If the target word
was "think" and the recogniser returned "sink", we call the word mispronounced and give a
sound-specific tip. This is not acoustic scoring (no phoneme model is involved), so it
can be fooled by recogniser errors; the UI says so.
"""
from __future__ import annotations

import difflib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

import skills

DATA = Path(__file__).parent / "data"

# G1 fair feedback: result provenance and the honest-uncertainty threshold.
FEEDBACK_VERSION = "1.0"
NORMALIZATION_VERSION = "1.1"   # 1.1: word-boundary reconciliation (every day / everyday)
UNCERTAIN_READ_ACCURACY = 35    # a read below this is a mishearing/wrong sentence, not a grade
BASIS = {"read": "word_accuracy", "build": "exact_match", "free": "rubric"}

# Extra English rules for common errors. Same shape as the repo's grammar_rules.json.
EXTRA_RULES = [
    {"id": "how_is_you", "nodeId": "grammar.verbs", "pattern": r"\bhow is (you|they|we)\b",
     "replacement": r"how are \1", "explanation": "Use are with you, we and they."},
    {"id": "you_is", "nodeId": "grammar.verbs", "pattern": r"\b(you|we|they) is\b",
     "replacement": r"\1 are", "explanation": "Use are with you, we and they."},
    {"id": "a_before_vowel", "nodeId": "grammar.articles", "pattern": r"\ba ([aeiou][a-z]+)\b",
     "replacement": r"an \1", "explanation": "Use an before a word that starts with a vowel sound."},
    {"id": "an_before_consonant", "nodeId": "grammar.articles", "pattern": r"\ban ([bcdfgjklmnpqrstvwxyz][a-z]+)\b",
     "replacement": r"a \1", "explanation": "Use a before a word that starts with a consonant sound."},
    {"id": "i_am_agree", "nodeId": "grammar.verbs", "pattern": r"\bI am agree\b",
     "replacement": "I agree", "explanation": "Agree is a verb. Say I agree, not I am agree."},
    {"id": "he_dont", "nodeId": "grammar.simple_present_agreement", "pattern": r"\b(he|she|it) don't\b",
     "replacement": r"\1 doesn't", "explanation": "Use doesn't with he, she or it."},
    {"id": "more_than_er", "nodeId": "grammar.comparatives", "pattern": r"\bmore (taller|bigger|smaller|faster|older|younger)\b",
     "replacement": r"\1", "explanation": "Do not use more with an -er word. Say taller, not more taller."},
    {"id": "was_were", "nodeId": "grammar.verbs", "pattern": r"\b(we|they|you) was\b",
     "replacement": r"\1 were", "explanation": "Use were with we, they and you."},
    {"id": "he_were", "nodeId": "grammar.verbs", "pattern": r"\b(he|she|it|I) were\b",
     "replacement": r"\1 was", "explanation": "Use was with I, he, she and it."},
    {"id": "didnt_past", "nodeId": "grammar.irregular_past", "pattern": r"\bdidn't (went|came|saw|took|ate|got)\b",
     "replacement": lambda m: "didn't " + {"went": "go", "came": "come", "saw": "see", "took": "take", "ate": "eat", "got": "get"}[m.group(1)],
     "explanation": "After did not, use the base form of the verb."},
    {"id": "much_countable", "nodeId": "grammar.quantity", "pattern": r"\bmuch (friends|books|students|people|apples)\b",
     "replacement": r"many \1", "explanation": "Use many with things you can count."},
]

# Spoken-English tips for sounds that are often hard, keyed by (target fragment, heard fragment).
SOUND_TIPS = [
    ("th", "t", "For th, put the tip of your tongue lightly between your teeth and blow air out."),
    ("th", "d", "For th, put the tip of your tongue lightly between your teeth. Do not touch the roof of your mouth."),
    ("th", "s", "For th, your tongue goes between your teeth. For s, it stays behind them."),
    ("th", "f", "For th, put your tongue lightly between your teeth. For f, your top teeth touch your lip."),
    ("w", "v", "For w, round your lips and do not touch your teeth. For v, your top teeth touch your lower lip."),
    ("v", "w", "For v, touch your top teeth to your lower lip and let your voice buzz."),
    ("sh", "s", "For sh, round your lips a little and pull your tongue back."),
    ("s", "sh", "For s, keep your lips relaxed and your tongue forward."),
    ("z", "j", "For z, keep your tongue still and let it buzz. For j, your tongue touches the roof first."),
    ("ch", "sh", "For ch, stop the air for a moment, then release it."),
    ("p", "b", "For p, push out a small puff of air. For b, use your voice."),
    ("f", "p", "For f, rest your top teeth on your lower lip and blow air."),
    ("ed", "d", "Check the ending of the word. Say the final sound clearly."),
]


@dataclass
class WordResult:
    target: str
    heard: str | None
    status: str  # correct | close | wrong | missed


def tokens(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text.lower().replace("’", "'"))


def _load_rules() -> list[dict]:
    path = DATA / "grammar_rules.json"
    rules = json.loads(path.read_text(encoding="utf-8")) if path.exists() else []
    out = []
    for r in rules:
        repl = re.sub(r"\$(\d)", r"\\\1", r["replacement"])
        out.append({**r, "replacement": repl})
    return out + EXTRA_RULES


RULES = _load_rules()
_COMPILED = []
for _r in RULES:
    _flags = 0 if "[A-Z]" in _r["pattern"] else re.IGNORECASE
    _COMPILED.append((_r, re.compile(_r["pattern"], _flags)))


def check_grammar(text: str) -> list[dict]:
    """Return one issue per matched rule: what was said, a fix, and why."""
    issues = []
    seen: set[tuple[int, int]] = set()
    for rule, rx in _COMPILED:
        for m in rx.finditer(text):
            fixed = m.expand(rule["replacement"]) if isinstance(rule["replacement"], str) else rule["replacement"](m)
            key = (m.start(), m.end())
            if key in seen or fixed.lower() == m.group(0).lower():
                continue  # same words already flagged by another rule
            seen.add(key)
            issues.append({
                "rule": rule["id"],
                "skill": skills.normalise(rule["nodeId"]),
                "said": m.group(0),
                "fix": fixed,
                "start": m.start(),
                "end": m.end(),
                "why": rule["explanation"],
            })
    issues.sort(key=lambda i: i["start"])
    return issues


def _sound_tip(target: str, heard: str) -> str | None:
    for want, got, tip in SOUND_TIPS:
        if want in target and got in heard and want not in heard:
            return tip
    return None


def compare_reading(target: str, spoken: str) -> tuple[list[WordResult], list[str]]:
    """Align the heard words to the target words; return per-target results and extra words."""
    t, s = tokens(target), tokens(spoken)
    results: list[WordResult] = []
    extras: list[str] = []
    matcher = difflib.SequenceMatcher(a=t, b=s, autojunk=False)
    for op, a0, a1, b0, b1 in matcher.get_opcodes():
        if op == "equal":
            results += [WordResult(w, w, "correct") for w in t[a0:a1]]
        elif op == "delete":
            results += [WordResult(w, None, "missed") for w in t[a0:a1]]
        elif op == "insert":
            extras += s[b0:b1]
        else:  # replace: pair words in order, leftovers are missed or extra
            tw, sw = t[a0:a1], s[b0:b1]
            # The recogniser may split or join words ("every day" <-> "everyday",
            # "log in" <-> "login"). If the block is the same letters, only segmented
            # differently, it is the right reading, not a learner mistake.
            if "".join(tw) == "".join(sw):
                results += [WordResult(w, w, "correct") for w in tw]
                continue
            for i, w in enumerate(tw):
                if i < len(sw):
                    ratio = difflib.SequenceMatcher(a=w, b=sw[i]).ratio()
                    results.append(WordResult(w, sw[i], "close" if ratio >= 0.75 else "wrong"))
                else:
                    results.append(WordResult(w, None, "missed"))
            extras += sw[len(tw):]
    return results, extras


def analyse(kind: str, target: str | None, transcript: str, answer: str | None = None) -> dict:
    """Score one attempt. kind: read | free | build."""
    transcript = (transcript or "").strip()
    grammar = check_grammar(transcript) if kind in ("read", "free") else []
    words: list[dict] = []
    extras: list[str] = []
    tips: list[str] = []
    sound_codes: list[str] = []
    accuracy = None

    if kind == "read":
        results, extras = compare_reading(target or "", transcript)
        words = [w.__dict__ for w in results]
        n = max(len(results), 1)
        accuracy = round(100 * (sum(w.status == "correct" for w in results) + 0.5 * sum(w.status == "close" for w in results)) / n)
        seen_tips: set[str] = set()
        for w in results:
            if w.status in ("wrong", "close") and w.heard:
                code = skills.sound_skill(w.target, w.heard)
                if code is None or skills.is_accent_only(code):
                    continue  # a different accent, not a mistake: never flag it
                sound_codes.append(code)
                tip = _sound_tip(w.target, w.heard) or f"we heard “{w.heard}”. Listen to the word again and say it slowly."
                if tip not in seen_tips:
                    seen_tips.add(tip)
                    tips.append(f"{w.target}: {tip}")
        missed = [w.target for w in results if w.status == "missed"]
        if missed:
            tips.append("You skipped: " + ", ".join(missed) + ". Read the sentence slowly once, then say it again.")
        if extras:
            tips.append("Extra words heard: " + ", ".join(extras) + ". Stay close to the sentence on the page.")
        score = accuracy - 5 * len(grammar)
    elif kind == "build":
        got, want = tokens(transcript), tokens(answer or target or "")
        ratio = difflib.SequenceMatcher(a=want, b=got, autojunk=False).ratio()
        accuracy = round(100 * ratio)
        score = 100 if got == want else accuracy
        if got != want:
            tips.append("Check the word order. A simple sentence usually goes: who, does what, where or when.")
    else:  # free speaking
        n_words = len(tokens(transcript))
        if n_words == 0:
            score = 0
            tips.append("Nothing was heard. Check the microphone, or type what you said.")
        else:
            score = 100 - 20 * len(grammar)
            if n_words < 4:
                score = min(score, 70)
                tips.append("Try a longer answer: at least one full sentence of four words or more.")

    for g in grammar:
        tips.append(f"Say “{g['fix']}” instead of “{g['said']}”. {g['why']}")
    score = max(0, min(100, round(score)))
    for c in sound_codes:
        if c not in [g.get("skill") for g in grammar]:
            grammar.append({"rule": "sound", "skill": c, "said": "", "fix": "", "start": 0, "end": 0,
                            "why": skills.practice_hint(c), "sound_only": True})
    if not tips and score >= 90:
        tips.append("Clear and correct. Try the next one.")

    # G1: an explicit unscored state for audio we could not fairly grade, instead of an
    # invented low number, plus the basis of the grade and provenance versions.
    evaluation_status, uncertainty_reasons = "scored", []
    if kind == "read" and accuracy is not None and accuracy < UNCERTAIN_READ_ACCURACY:
        evaluation_status, uncertainty_reasons = "unscored", ["low_match"]
    elif kind == "free" and len(tokens(transcript)) == 0:
        evaluation_status, uncertainty_reasons = "unscored", ["no_speech"]
    return {"score": score, "accuracy": accuracy, "words": words, "extra_words": extras,
            "grammar": grammar, "tips": tips,
            "evaluation_status": evaluation_status, "uncertainty_reasons": uncertainty_reasons,
            "basis": BASIS.get(kind, "rubric"),
            "feedback_version": FEEDBACK_VERSION, "normalization_version": NORMALIZATION_VERSION}


# --- Optional server-side speech-to-text -------------------------------------------------
# Used only when the browser sends audio without a transcript. Install faster-whisper and set
# VAACHAK_WHISPER_MODEL (for example "base.en" or a local folder) to enable it.
_whisper = None


def server_asr_available() -> bool:
    """True when the server can turn audio into text by itself (Groq, or a local Whisper)."""
    import ai

    if ai.configured():
        return True
    if not os.environ.get("VAACHAK_WHISPER_MODEL"):
        return False
    try:
        import faster_whisper  # noqa: F401
        return True
    except Exception:
        return False


def transcribe_file(path: str, mime: str = "audio/webm") -> str:
    """Audio file to text. Tries the cloud model first, then a local Whisper if installed."""
    global _whisper
    import ai

    if ai.configured():
        text = ai.transcribe(path, mime)
        if text:
            return text
    if not os.environ.get("VAACHAK_WHISPER_MODEL"):
        return ""
    from faster_whisper import WhisperModel

    if _whisper is None:
        _whisper = WhisperModel(os.environ["VAACHAK_WHISPER_MODEL"], device="cpu", compute_type="int8")
    segments, _ = _whisper.transcribe(path, language="en", vad_filter=True)
    return " ".join(s.text.strip() for s in segments).strip()


# ----------------------------------------------------------------------------- rules + model
# Below this reading accuracy we assume we heard the wrong thing, not a learner mistake.
MISREAD_FLOOR = 35

def _as_tips(ai_result: dict) -> list[str]:
    tips = []
    if ai_result.get("verdict"):
        tips.append(ai_result["verdict"])
    tips += list(ai_result.get("strengths") or [])
    return tips


def analyse_full(kind: str, target: str | None, transcript: str, answer: str | None = None,
                 prompt: str | None = None, level: str = "A1") -> dict:
    """Score an attempt with the rules, then let the model improve the explanation.

    The rules always run, so a learner still gets feedback with no internet and no key.
    When the model answers, it replaces the rule-written corrections, because it can judge
    a sentence it has never seen; the word-by-word reading marks stay as they are.
    """
    import ai

    base = analyse(kind, target, transcript, answer)
    base["source"] = "rules"
    if kind == "build" or not ai.configured():
        return base
    coached = ai.coach(kind, target, transcript, prompt=prompt, level=level)
    if not coached:
        return base

    base["source"] = "ai"
    base["next_line"] = coached.get("next_line") or ""
    base["verdict"] = coached.get("verdict") or ""
    base["strengths"] = list(coached.get("strengths") or [])
    if coached["grammar"]:
        base["grammar"] = coached["grammar"]
    elif kind == "free":
        base["grammar"] = []  # the model saw no mistakes; do not leave rule guesses behind
    if kind == "read":
        # Reading aloud is scored on the words actually read; the model only explains.
        # The word-by-word marks already capture a misread word, so no second penalty here.
        base["score"] = base["accuracy"] if base.get("accuracy") is not None else coached["score"]
        if (base.get("accuracy") or 0) < MISREAD_FLOOR:
            # Almost nothing matched: this is the wrong sentence or background noise, not a
            # grammar problem. Coaching the words we heard would be confusing and wrong.
            base["grammar"], base["strengths"], base["next_line"] = [], [], ""
            base["verdict"] = "That did not sound like the sentence on the page."
            base["tips"] = ["Tap Record and read the sentence above, slowly and close to the microphone."]
            return base
    else:
        base["score"] = coached["score"]
    base["tips"] = _as_tips(coached) + [f"Say “{t['fix']}” instead of “{t['said']}”. {t['why']}" for t in base["grammar"]]
    return base
