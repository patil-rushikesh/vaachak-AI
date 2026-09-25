"""Plain-language views of saved evidence; no model calls or new assessment.

Scores are fractions in [0, 1]. Timing and pitch observations never have a
score. Call this after any role-specific result redaction; private semantic
suggestions are deliberately unused even if supplied here.
"""

import math
import re


def _dict(value):
    return value if isinstance(value, dict) else {}


def _number(value, low=0, high=1):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    # Check bounds before math.isfinite, which can overflow on huge integers.
    return float(value) if low <= value <= high and math.isfinite(value) else None


def _count(value, maximum=600):
    return value if type(value) is int and 0 <= value <= maximum else None


def _items(value):
    return value[:1200] if isinstance(value, list) else []


def _word(value):
    if not isinstance(value, str) or len(value) > 80:
        return None
    value = value.strip().rstrip(".,!?;:")
    return value if re.fullmatch(r"[^\W_]+(?:['’\-][^\W_]+)*", value) else None


def _percent(value):
    return f"{round(value * 100):d}%"


def _dimension(key, label, status, value, detail, score=None):
    return {"key": key, "label": label, "status": status,
            "value_text": value, "detail": detail, "score": score}


def _pitch_dimension(result):
    pitch = _dict(result.get("pitch"))
    summary = _dict(pitch.get("summary"))
    seconds = _number(summary.get("voiced_seconds"), 0.02, 120)
    median = _number(summary.get("median_f0_hz"), 65, 650)
    if pitch.get("status") != "available" or seconds is None or median is None:
        return _dimension("pitch", "Voice movement", "unavailable", "Not enough pitch evidence",
                          "A clear pitch line is not available. This does not mean the reading was wrong.")
    detail = f"Pitch was detected for about {seconds:.1f} seconds. The line shows how your voice rises and falls."
    comparison = _dict(pitch.get("reference_comparison"))
    points = [point for point in _items(comparison.get("points")) if isinstance(point, dict)
              and _word(point.get("word")) and all(_number(point.get(key), -60, 60) is not None
                  for key in ("student_semitones", "reference_semitones"))]
    value = "Your voice pattern is ready to view"
    if comparison.get("status") == "available" and len(points) >= 3:
        value = "Your voice pattern is compared with the example"
        detail += " Each voice is compared with its own typical pitch; a naturally higher or lower voice is not a mistake."
    detail += " This is experimental evidence, not a grade or an emotion assessment."
    return _dimension("pitch", "Voice movement", "observed", value, detail)


def _reading(result, score, status):
    review = _dict(result.get("teacher_review"))
    teacher_score = score if status == "completed" and review else None
    uncertain = status != "completed" or bool(result.get("review_reason"))
    accuracy = _number(result.get("word_accuracy"))
    graded_accuracy = accuracy if not uncertain else None
    counts = _dict(result.get("counts"))
    expected = _count(result.get("expected_word_count"))
    matched = _count(counts.get("match"))
    coherent = (expected is not None and expected > 0 and matched is not None and matched <= expected)
    # Reject contradictory counters instead of inventing a total or percentage.
    deletions, substitutions = _count(counts.get("deletion")), _count(counts.get("substitution"))
    if coherent and deletions is not None and substitutions is not None:
        coherent = matched + deletions + substitutions == expected
    extra = _count(counts.get("insertion"))

    if status == "pending":
        headline, summary = "Your recording is being checked", "Your recording is saved. Feedback will appear when analysis finishes."
        steps = ["Wait for the feedback before sending the same recording again."]
    elif status == "failed":
        headline, summary = "Automatic feedback could not finish", "Your attempt is saved. No automatic score is available for this attempt."
        steps = ["Ask your teacher to review the recording or retry analysis."]
    elif teacher_score is not None:
        headline = "Your teacher has reviewed this attempt"
        summary = f"Your teacher's overall score is {_percent(teacher_score)}. The word and voice observations below are separate evidence."
        steps = []
    elif uncertain or accuracy is None:
        headline, summary = "Your teacher will review this recording", "Automatic word feedback is uncertain or unavailable. No final automatic score is shown."
        steps = ["Listen with your teacher before treating recognized word differences as mistakes."]
    else:
        headline = "Your reading feedback is ready"
        summary = (f"Speech recognition matched {matched} of {expected} words in the sentence."
                   if coherent else f"The automatic word-match score is {_percent(accuracy)}.")
        summary += " Listen to check any words the system may have misheard."
        steps = []

    word_value = "No automatic word score"
    word_status = "pending" if status == "pending" else "needs_review" if uncertain else "unavailable"
    if status not in {"pending", "failed"}:
        if coherent:
            word_value = f"{matched} of {expected} words matched" + (" (provisional)" if uncertain else "")
        elif accuracy is not None and not uncertain:
            word_value = f"{_percent(accuracy)} automatic word match"
        if graded_accuracy is not None:
            word_status = "assessed"
        elif coherent and not uncertain:
            word_status = "observed"
    detail = "Speech recognition can mishear words. Missing, changed and extra words affect word matching; this is not a pronunciation grade."
    if status not in {"pending", "failed"} and extra:
        detail += f" {extra} extra {'word was' if extra == 1 else 'words were'} recognized" + (" provisionally." if uncertain else ".")
    dimensions = [_dimension("word_match", "Words in the sentence", word_status, word_value, detail, graded_accuracy)]
    if teacher_score is not None:
        dimensions.insert(0, _dimension("teacher_review", "Teacher's overall review", "assessed",
                                       _percent(teacher_score), "Your teacher's judgment is separate from the automatic word-match score.", teacher_score))

    practice, seen = [], set()
    if status not in {"pending", "failed"}:
        for item in _items(result.get("alignment")):
            item = _dict(item)
            word = _word(item.get("expected"))
            operation = item.get("operation")
            if operation not in ("deletion", "substitution") or not word or word in seen:
                continue
            seen.add(word)
            heard = _word(item.get("spoken"))
            if uncertain:
                reason = "Possible word difference; listen with your teacher to check."
            elif operation == "substitution" and heard:
                reason = f"Recognized as “{heard}”; listen to check."
            else:
                reason = "Not matched in the recognized words; listen to check."
            practice.append({"word": word, "reason": reason})
            if len(practice) == 3:
                break
        if practice:
            steps.append("Listen to " + ", ".join(f"“{item['word']}”" for item in practice) + " in the example, then practise the sentence again.")
        if extra:
            steps.append("Compare the recording with the written sentence and check for extra words.")

    # Timings rely on ASR, so uncertain recognition also makes these provisional.
    timing = _dict(result.get("pace"))
    reference = _dict(result.get("reference_comparison"))
    wpm = _number(timing.get("words_per_minute"), 1, 1200)
    pace_value, pace_detail, pace_status = "Not available", "Reliable word timings are needed to describe reading pace.", "unavailable"
    ratio = None
    if status not in {"pending", "failed"} and timing.get("status") == "available" and wpm is not None:
        pace_value = f"About {round(wpm)} words per minute"
        pace_status = "needs_review" if uncertain else "observed"
        pace_detail = "This describes reading speed, not correctness. A comfortable, clear pace matters more than copying a speed exactly."
        reference_wpm = _number(reference.get("reference_words_per_minute"), 1, 1200)
        candidate = _number(reference.get("pace_ratio"), 0.1, 10)
        if reference.get("status") == "available" and reference_wpm is not None and candidate is not None:
            measured = wpm / reference_wpm
            if abs(candidate - measured) <= max(0.02, 0.02 * measured):
                ratio = candidate
        if ratio is not None:
            delta = round(abs(ratio - 1) * 100)
            pace_value = ("About the same pace as the example" if delta < 3 else
                          f"About {delta}% {'slower' if ratio < 1 else 'faster'} than the example")
            pace_detail += f" Your estimate: {round(wpm)} words per minute; example: {round(reference_wpm)}."
        if uncertain:
            pace_detail = "Provisional because word recognition was uncertain. " + pace_detail
        elif ratio is not None and (ratio < 0.85 or ratio > 1.15):
            steps.append("Read alongside the example once, then try again at a comfortable pace.")
    dimensions.append(_dimension("pace", "Reading pace", pace_status, pace_value, pace_detail))

    comparisons = []
    if status not in {"pending", "failed"} and reference.get("status") == "available":
        for item in _items(reference.get("pause_comparisons")):
            item = _dict(item)
            word = _word(item.get("after_word"))
            student = _number(item.get("student_seconds"), 0, 120)
            teacher = _number(item.get("reference_seconds"), 0, 120)
            if word and student is not None and teacher is not None:
                comparisons.append((abs(student - teacher), word, student, teacher))
    if comparisons:
        comparisons.sort(reverse=True)
        difference, word, student, teacher = comparisons[0]
        # A readability tolerance, not a claim about a correct pause length.
        noticeable = difference + 1e-9 >= 0.15
        description = ("longer" if student > teacher else "shorter") if noticeable else "similar"
        pause_value = f"A {description} pause after “{word}”"
        pause_detail = f"You: {student:.2f}s; example: {teacher:.2f}s. These are estimated gaps between matching words, not a punctuation grade. Listen to that part in both recordings."
        if uncertain:
            pause_value = f"Possibly a {description} pause after “{word}”"
            pause_detail = "Provisional because word recognition was uncertain. " + pause_detail
        dimensions.append(_dimension("pauses", "Pauses between words", "needs_review" if uncertain else "observed", pause_value, pause_detail))
        if noticeable:
            steps.append(f"Listen to the example after “{word}”, then practise the pause in your sentence.")
    else:
        dimensions.append(_dimension("pauses", "Pauses between words", "unavailable", "No reliable pause comparison",
                                     "Matching word timings from both recordings are needed. This does not mean your pauses were wrong."))
    dimensions.append(_pitch_dimension(result) if status != "pending" else
                      _dimension("pitch", "Voice movement", "pending", "Waiting for analysis", "Pitch observations will be shown separately from scores."))
    dimensions.append(_dimension("pronunciation", "Pronunciation", "not_assessed", "Not assessed",
                                 "Word recognition and pitch do not tell us whether each speech sound was pronounced correctly."))
    if not steps:
        steps = ["Listen to both recordings and choose one part to practise with your teacher."]
    return {"headline": headline, "summary": summary, "next_steps": steps[:4],
            "dimensions": dimensions, "word_practice": practice}


def learner_feedback(kind, result, score, status):
    """Turn saved evidence into a bounded, JSON-safe learner-facing view.

    Unknown/malformed state is reviewable, never a guessed grade. The input is
    not mutated. Output statuses are assessed/observed/not_assessed/unavailable/
    needs_review/pending; only actual assessment dimensions have numeric scores.
    """
    result, score = _dict(result), _number(score)
    status = status if status in ("completed", "pending", "needs_review", "failed") else "needs_review"
    if kind == "read_aloud":
        return _reading(result, score, status)
    labels = {"choice": "Word choice", "matching": "Matching words", "meaning": "Understanding the meaning"}
    label = labels.get(kind, "Practice") if isinstance(kind, str) else "Practice"
    reviewed = bool(_dict(result.get("teacher_review")))
    settled = status == "completed" and score is not None
    if settled:
        headline = "Your teacher has reviewed your answer" if reviewed else "Your practice feedback is ready"
        summary = f"{'Your teacher’s score' if reviewed else 'Your practice score'} is {_percent(score)}."
        detail = "This score reflects your teacher's review." if reviewed else "This is the saved assessment for this practice."
        value = _percent(score)
        correct, total = _count(result.get("correct_count")), _count(result.get("total_count"))
        if kind == "matching" and not reviewed and correct is not None and total and correct <= total:
            value = f"{correct} of {total} pairs matched correctly"
        steps = (["Read your teacher's feedback and practise the idea again."] if reviewed else
                 ["Try another practice when you are ready."] if score == 1 else
                 ["Review the question and your teacher's notes, then try again."])
        dimension = _dimension("teacher_review" if reviewed else "practice", label, "assessed", value, detail, score)
    else:
        headline = {"pending": "Your answer is being checked", "failed": "Automatic feedback could not finish"}.get(status, "Your teacher will review your answer")
        summary = "Your answer is saved. No final score is available yet."
        steps = ["Your teacher can review the answer and give you feedback."]
        dimension = _dimension("practice", label, "pending" if status == "pending" else "needs_review", "Awaiting feedback",
                               "An automatic suggestion is not a confirmed grade.")
    return {"headline": headline, "summary": summary, "next_steps": steps,
            "dimensions": [dimension], "word_practice": []}
