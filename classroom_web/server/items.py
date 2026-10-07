"""Task items shared by assignments and course lessons.

Speaking tasks (graded by feedback.py):
  read    {text}                      read a sentence aloud
  free    {prompt}                    answer a question in full sentences
  build   {words[], answer}           put the words in order
Quiz tasks (graded here, no speech needed):
  choice  {prompt, options[], correct, explain?}     pick the right answer
  fill    {prompt, options[], correct, explain?}     prompt contains ___ ; pick the word that fits
  listen  {text, options[], correct, explain?}       hear the sentence (browser voice), pick what it says
"""
from __future__ import annotations

from typing import Literal

from fastapi import HTTPException
from pydantic import BaseModel, Field

import feedback

SPEAKING_KINDS = ("read", "free", "build")
QUIZ_KINDS = ("choice", "fill", "listen")


class ItemIn(BaseModel):
    kind: Literal["read", "free", "build", "choice", "fill", "listen"]
    text: str | None = Field(default=None, max_length=300)
    prompt: str | None = Field(default=None, max_length=300)
    words: list[str] | None = Field(default=None, max_length=20)
    answer: str | None = Field(default=None, max_length=300)
    options: list[str] | None = Field(default=None, max_length=6)
    correct: int | None = Field(default=None, ge=0, le=5)
    explain: str | None = Field(default=None, max_length=300)


def clean_item(i: ItemIn) -> dict:
    """Validate one item from a teacher and return the stored form."""
    if i.kind == "read" and (i.text or "").strip():
        return {"kind": "read", "text": i.text.strip()}
    if i.kind == "free" and (i.prompt or "").strip():
        return {"kind": "free", "prompt": i.prompt.strip()}
    if i.kind == "build" and i.words and len(i.words) >= 2 and (i.answer or "").strip():
        if sorted(feedback.tokens(" ".join(i.words))) != sorted(feedback.tokens(i.answer)):
            raise HTTPException(422, "The build answer must use exactly the given words.")
        return {"kind": "build", "words": [w.strip() for w in i.words], "answer": i.answer.strip()}
    if i.kind in QUIZ_KINDS:
        stem = (i.text if i.kind == "listen" else i.prompt) or ""
        opts = [o.strip() for o in (i.options or []) if o and o.strip()]
        if not stem.strip():
            raise HTTPException(422, "Write the question for each quiz item." if i.kind != "listen" else "Write the sentence that will be spoken.")
        if len(opts) < 2:
            raise HTTPException(422, "A quiz item needs at least two answer options.")
        if len({o.lower() for o in opts}) != len(opts):
            raise HTTPException(422, "Answer options must all be different.")
        if i.correct is None or i.correct >= len(opts):
            raise HTTPException(422, "Mark which option is correct.")
        if i.kind == "fill" and "___" not in stem:
            raise HTTPException(422, "A fill-in item needs ___ where the word goes.")
        out = {"kind": i.kind, "options": opts, "correct": i.correct}
        out["text" if i.kind == "listen" else "prompt"] = stem.strip()
        if (i.explain or "").strip():
            out["explain"] = i.explain.strip()
        return out
    raise HTTPException(422, "Each item needs its text, prompt, words, or options.")


def public_item(item: dict) -> dict:
    """What a learner may see before answering: no correct option, no explanation."""
    if item["kind"] in QUIZ_KINDS:
        # A listen item keeps its text because the browser's voice has to read it aloud.
        return {k: v for k, v in item.items() if k not in ("correct", "explain")}
    return item


def grade_quiz(item: dict, chosen: int) -> dict:
    """Score a quiz answer. Result has the same list fields as speaking results so stats keep working."""
    if not 0 <= chosen < len(item["options"]):
        raise HTTPException(422, "Pick one of the options.")
    ok = chosen == item["correct"]
    right = item["options"][item["correct"]]
    tips = [] if ok else [f"The right answer is “{right}”."]
    if item.get("explain"):
        tips.append(item["explain"])
    stem = item.get("prompt") or item.get("text") or ""
    return {
        "score": 100 if ok else 0, "accuracy": 100 if ok else 0, "words": [], "extra_words": [], "grammar": [],
        "tips": tips, "correct": ok, "correct_index": item["correct"], "chosen": chosen, "chosen_text": item["options"][chosen],
        "target": right, "question": stem,
    }
