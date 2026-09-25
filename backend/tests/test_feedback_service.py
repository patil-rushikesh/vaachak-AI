"""Truthful display of saved evidence; these are not model-accuracy tests."""

import copy
import json

import pytest

from vaachak_backend.feedback_service import learner_feedback


@pytest.fixture
def reading():
    return {
        "word_accuracy": 0.4, "expected_word_count": 5,
        "counts": {"match": 3, "deletion": 1, "substitution": 1, "insertion": 1},
        "alignment": [
            {"operation": "deletion", "expected": "books", "spoken": None},
            {"operation": "substitution", "expected": "house", "spoken": "horse"},
            {"operation": "deletion", "expected": "books", "spoken": None},
            {"operation": "insertion", "expected": None, "spoken": "school"},
        ],
        "pace": {"status": "available", "words_per_minute": 108},
        "reference_comparison": {
            "status": "available", "reference_words_per_minute": 120, "pace_ratio": 0.9,
            "pause_comparisons": [{"after_word": "house", "student_seconds": 0.8,
                                   "reference_seconds": 0.2, "difference_seconds": 999}],
        },
        "pitch": {
            "status": "available", "score": 1,
            "summary": {"median_f0_hz": 220, "voiced_seconds": 1.4},
            "reference_comparison": {"status": "available", "points": [
                {"word": word, "student_semitones": 1, "reference_semitones": -1}
                for word in ["this", "is", "house"]]},
        },
    }


def dimensions(feedback):
    return {dimension["key"]: dimension for dimension in feedback["dimensions"]}


def test_reading_explains_words_speed_pauses_without_inventing_grades(reading):
    result = learner_feedback("read_aloud", reading, 0.4, "completed")
    dims = dimensions(result)
    assert dims["word_match"]["score"] == 0.4
    assert dims["word_match"]["value_text"] == "3 of 5 words matched"
    assert "1 extra word was" in dims["word_match"]["detail"]
    assert dims["pace"]["value_text"] == "About 10% slower than the example"
    assert dims["pace"]["status"] == "observed"
    assert dims["pauses"]["value_text"] == "A longer pause after “house”"
    assert "You: 0.80s; example: 0.20s" in dims["pauses"]["detail"]
    assert any("after “house”" in step for step in result["next_steps"])
    for key in ["pace", "pauses", "pitch", "pronunciation"]:
        assert dims[key]["score"] is None
    assert dims["pronunciation"]["status"] == "not_assessed"
    assert dims["pitch"]["status"] == "observed"
    assert "naturally higher or lower voice is not a mistake" in dims["pitch"]["detail"]
    assert "emotion assessment" in dims["pitch"]["detail"]
    assert [item["word"] for item in result["word_practice"]] == ["books", "house"]
    assert "horse" in result["word_practice"][1]["reason"]


def test_teacher_score_does_not_replace_automatic_word_evidence(reading):
    reading["teacher_review"] = {"score": 0.95, "feedback": "Reviewed by teacher"}
    feedback = learner_feedback("read_aloud", reading, 0.95, "completed")
    dims = dimensions(feedback)
    assert dims["teacher_review"]["score"] == 0.95
    assert dims["word_match"]["score"] == 0.4
    assert "teacher's overall score is 95%" in feedback["summary"]
    assert "separate" in feedback["summary"]


def test_completed_does_not_substitute_overall_score_for_missing_word_accuracy():
    feedback = learner_feedback("read_aloud", {}, 1, "completed")
    assert dimensions(feedback)["word_match"]["score"] is None
    assert "100%" not in json.dumps(feedback)


@pytest.mark.parametrize("status", ["pending", "failed", "needs_review", "unknown", None])
def test_unsettled_states_never_publish_stale_numeric_scores(reading, status):
    reading["teacher_review"] = {"score": 1}
    feedback = learner_feedback("read_aloud", reading, 1, status)
    assert all(d["score"] is None for d in feedback["dimensions"])
    assert "teacher_review" not in dimensions(feedback)
    if status in {"pending", "failed"}:
        assert feedback["word_practice"] == []
        assert "words matched" not in dimensions(feedback)["word_match"]["value_text"]


def test_low_confidence_qualifies_differences_and_timing(reading):
    reading["review_reason"] = "low_asr_confidence"
    feedback = learner_feedback("read_aloud", reading, None, "needs_review")
    dims = dimensions(feedback)
    assert dims["word_match"]["score"] is None
    assert "provisional" in dims["word_match"]["value_text"]
    assert "Provisional" in dims["pace"]["detail"]
    assert "Provisional" in dims["pauses"]["detail"]
    assert all("Possible word difference" in item["reason"] for item in feedback["word_practice"])
    assert "before treating" in feedback["next_steps"][0]


def test_teacher_review_does_not_make_low_confidence_asr_a_grade(reading):
    reading.update({"teacher_review": {"score": 0.8}, "review_reason": "low_asr_confidence"})
    dims = dimensions(learner_feedback("read_aloud", reading, 0.8, "completed"))
    assert dims["teacher_review"]["score"] == 0.8
    assert dims["word_match"]["score"] is None
    assert dims["word_match"]["status"] == "needs_review"


def test_pitch_survives_unavailable_asr_without_a_score(reading):
    feedback = learner_feedback("read_aloud", {"pitch": reading["pitch"], "review_reason": "speech_model_not_configured"}, None, "needs_review")
    dims = dimensions(feedback)
    assert dims["pitch"]["status"] == "observed"
    assert dims["word_match"]["score"] is None
    assert all(d["score"] is None for d in dims.values())
    assert feedback["word_practice"] == []


def test_failed_analysis_can_still_show_saved_ungraded_pitch_evidence(reading):
    feedback = learner_feedback("read_aloud", reading, 1, "failed")
    assert dimensions(feedback)["pitch"]["status"] == "observed"
    assert all(d["score"] is None for d in feedback["dimensions"])


@pytest.mark.parametrize(("student", "reference", "description", "tip"), [
    (0.4, 0.34, "similar", False), (0.2, 0.2, "similar", False),
    (0.2, 0.8, "shorter", True), (0.35, 0.2, "longer", True),
])
def test_pause_description_and_practice_tip_use_descriptive_tolerance(reading, student, reference, description, tip):
    reading["reference_comparison"]["pause_comparisons"] = [
        {"after_word": "house", "student_seconds": student, "reference_seconds": reference}]
    feedback = learner_feedback("read_aloud", reading, 0.4, "completed")
    pause = dimensions(feedback)["pauses"]
    assert pause["value_text"] == f"A {description} pause after “house”"
    assert pause["score"] is None and pause["status"] == "observed"
    assert any("practise the pause" in step for step in feedback["next_steps"]) is tip


@pytest.mark.parametrize("ratio", [None, 0, -1, float("nan"), float("inf"), 100000000, True, "0.9", 0.5])
def test_invalid_or_inconsistent_ratios_do_not_create_comparison_percentages(reading, ratio):
    reading["reference_comparison"]["pace_ratio"] = ratio
    pace = dimensions(learner_feedback("read_aloud", reading, 0.4, "completed"))["pace"]
    assert pace["value_text"] == "About 108 words per minute"
    assert "%" not in pace["value_text"]
    assert pace["score"] is None


@pytest.mark.parametrize("reference_speed", [0, None, float("nan"), float("inf"), 10**1000, False])
def test_bad_reference_speed_never_divides_by_zero_or_overflows(reading, reference_speed):
    reading["reference_comparison"]["reference_words_per_minute"] = reference_speed
    feedback = learner_feedback("read_aloud", reading, 0.4, "completed")
    assert dimensions(feedback)["pace"]["value_text"] == "About 108 words per minute"
    json.dumps(feedback, allow_nan=False)


@pytest.mark.parametrize(("speed", "ratio", "phrase"), [(120, 1, "same pace"), (144, 1.2, "20% faster")])
def test_pace_is_a_neutral_description(reading, speed, ratio, phrase):
    reading["pace"]["words_per_minute"] = speed
    reading["reference_comparison"]["pace_ratio"] = ratio
    pace = dimensions(learner_feedback("read_aloud", reading, 0.4, "completed"))["pace"]
    assert phrase in pace["value_text"]
    assert pace["status"] == "observed" and pace["score"] is None


@pytest.mark.parametrize("invalid", [0, -1, 10**1000, True, float("nan"), [], {}])
def test_invalid_word_totals_never_create_false_counts(reading, invalid):
    reading["expected_word_count"] = invalid
    feedback = learner_feedback("read_aloud", reading, 0.4, "completed")
    assert dimensions(feedback)["word_match"]["value_text"] == "40% automatic word match"
    json.dumps(feedback, allow_nan=False)


def test_contradictory_counts_are_not_presented_as_a_valid_total(reading):
    reading["counts"]["match"] = 5
    feedback = learner_feedback("read_aloud", reading, 0.4, "completed")
    assert "5 of 5" not in json.dumps(feedback)


@pytest.mark.parametrize("score", [None, float("nan"), float("inf"), -0.1, 1.1, 10**1000, True, "1"])
def test_invalid_scores_are_ungraded_for_all_kinds(reading, score):
    reading["word_accuracy"] = score
    for kind in ["read_aloud", "choice", "matching", "meaning"]:
        feedback = learner_feedback(kind, reading, score, "completed")
        assert all(d["score"] is None for d in feedback["dimensions"])
        json.dumps(feedback, allow_nan=False)


def test_zero_is_a_valid_score_not_an_absent_score():
    feedback = learner_feedback("choice", {"correct": False}, 0, "completed")
    assert feedback["dimensions"][0]["score"] == 0
    assert "0%" in feedback["summary"]
    assert "try again" in feedback["next_steps"][0]


@pytest.mark.parametrize("status", ["needs_review", "pending", "failed"])
def test_private_semantic_judgment_never_leaks_in_feedback(status):
    private = {"method": "ai_semantic_review", "suggested_score": 0.93,
               "classification": "correct", "explanation": "PRIVATE MODEL ANSWER", "confidence": 0.99,
               "accepted_answers": ["SECRET TEACHER KEY"], "rubric": "PRIVATE RUBRIC"}
    feedback = learner_feedback("meaning", private, 0.93, status)
    serialized = json.dumps(feedback)
    for value in ["93%", "PRIVATE", "SECRET", "classification", "confidence", "suggested_score"]:
        assert value not in serialized
    assert feedback["dimensions"][0]["score"] is None


def test_meaning_teacher_review_shows_confirmed_score_without_ai_text():
    feedback = learner_feedback("meaning", {"teacher_review": {"score": 0.8}, "suggested_score": 1,
                                            "explanation": "PRIVATE MODEL ANSWER"}, 0.8, "completed")
    assert feedback["dimensions"][0]["key"] == "teacher_review"
    assert feedback["dimensions"][0]["score"] == 0.8
    assert "PRIVATE" not in json.dumps(feedback)


def test_matching_counts_do_not_override_a_teacher_score():
    evidence = {"correct_count": 2, "total_count": 3}
    normal = learner_feedback("matching", evidence, 2 / 3, "completed")
    assert normal["dimensions"][0]["value_text"] == "2 of 3 pairs matched correctly"
    evidence["teacher_review"] = {"score": 0.8}
    reviewed = learner_feedback("matching", evidence, 0.8, "completed")
    assert reviewed["dimensions"][0]["value_text"] == "80%"
    assert reviewed["dimensions"][0]["score"] == 0.8


def test_word_practice_is_bounded_unique_and_excludes_markup(reading):
    reading["alignment"] = [{"operation": "deletion", "expected": value} for value in
                            ["<img src=x onerror=alert(1)>", "a" * 90, "one", "one", "two", "three", "four"]]
    feedback = learner_feedback("read_aloud", reading, 0.4, "completed")
    assert [item["word"] for item in feedback["word_practice"]] == ["one", "two", "three"]
    assert "<img" not in json.dumps(feedback)


def test_malformed_alignment_operation_is_ignored(reading):
    reading["alignment"] = [{"operation": [], "expected": "house"}, {"operation": {}, "expected": "books"}]
    assert learner_feedback("read_aloud", reading, 0.4, "completed")["word_practice"] == []


def test_invalid_pause_points_and_pitch_summary_are_not_evidence(reading):
    reading["reference_comparison"]["pause_comparisons"] = [None, {"after_word": "house", "student_seconds": float("nan"), "reference_seconds": 0}]
    reading["pitch"]["summary"]["median_f0_hz"] = float("inf")
    feedback = learner_feedback("read_aloud", reading, 0.4, "completed")
    assert dimensions(feedback)["pauses"]["status"] == "unavailable"
    assert dimensions(feedback)["pitch"]["status"] == "unavailable"
    json.dumps(feedback, allow_nan=False)


@pytest.mark.parametrize("result", [None, [], "bad", {"counts": [], "alignment": {}, "pace": [], "pitch": "bad"}])
def test_malformed_evidence_remains_safe(result):
    for kind in ["read_aloud", "meaning", None, []]:
        feedback = learner_feedback(kind, result, None, "needs_review")
        json.dumps(feedback, allow_nan=False)
        assert all(d["score"] is None for d in feedback["dimensions"])


def test_helper_does_not_modify_saved_evidence(reading):
    before = copy.deepcopy(reading)
    learner_feedback("read_aloud", reading, 0.4, "completed")
    assert reading == before
