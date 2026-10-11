import conftest  # noqa: F401  (sets import path)
import feedback as f


def test_grammar_rules_cover_common_indian_english_errors():
    cases = {
        "she go to school": "she goes", "we goes home": "we go", "I am agree": "I agree", "a apple": "an apple",
        "they was late": "they were", "he don't like tea": "he doesn't", "I discuss about it": "discuss", "more taller": "taller",
    }
    for said, fix in cases.items():
        assert any(fix.lower() in i["fix"].lower() for i in f.check_grammar(said)), said
    assert f.check_grammar("She goes to school every day.") == []
    assert f.check_grammar("An apple a day.") == []


def test_overlapping_rules_flag_once():
    assert len(f.check_grammar("a apple")) == 1


def test_reading_alignment_and_sound_tips():
    r = f.analyse("read", "Think about three things", "sink about free things")
    status = {w["target"]: w["status"] for w in r["words"]}
    assert status["think"] == "wrong" and status["about"] == "correct" and status["three"] == "wrong"
    assert any("tongue" in t for t in r["tips"]) and r["accuracy"] == 50


def test_reading_missed_close_and_extra_words():
    r = f.analyse("read", "The cat sat on the mat", "the cat on the mats please")
    status = {w["target"]: w["status"] for w in r["words"]}
    assert status["sat"] == "missed" and status["mat"] == "close"
    assert r["extra_words"] == ["please"]


def test_perfect_and_empty_reading():
    assert f.analyse("read", "I like tea.", "I like tea")["score"] == 100
    assert f.analyse("read", "I like tea.", "")["score"] == 0


def test_build_and_free():
    assert f.analyse("build", None, "She goes to school.", "she goes to school")["score"] == 100
    part = f.analyse("build", None, "goes she school to", "She goes to school")
    assert 0 < part["score"] < 100 and part["tips"]
    free = f.analyse("free", None, "yesterday I go to market")
    assert free["score"] < 100 and free["grammar"]
    assert f.analyse("free", None, "")["score"] == 0
    assert f.analyse("free", None, "I play football.")["score"] <= 70  # too short
    assert f.analyse("free", None, "I play football with my friends every Sunday.")["score"] == 100


# ----------------------------------------------------------------------------- skills and accent
import pytest  # noqa: E402

import skills  # noqa: E402


def test_every_rule_maps_to_a_real_skill():
    import feedback
    for rule in feedback.RULES:
        code = skills.normalise(rule["nodeId"])
        assert code in skills.SKILLS, f"{rule['id']} -> {code}"


@pytest.mark.parametrize("target,heard", [
    ("water", "waater"),    # a long vowel: Indian accent, correct English
    ("bought", "bot"),      # the recogniser spelling the same sound differently
    ("light", "lite"), ("school", "skool"), ("music", "musik"), ("phone", "fone"),
    ("box", "boks"), ("know", "no"),
])
def test_accent_and_spelling_are_never_treated_as_mistakes(target, heard):
    assert skills.sound_skill(target, heard) is None


@pytest.mark.parametrize("target,heard,code", [
    ("think", "tink", "PHON.TH"), ("three", "tree", "PHON.TH"), ("this", "dis", "PHON.TH"),
    ("very", "wery", "PHON.VW"), ("wine", "vine", "PHON.VW"),
    ("zero", "sero", "PHON.ZS"), ("ship", "sip", "PHON.SHS"),
    ("cat", "dog", "PHON.WORD"),
])
def test_sounds_that_change_meaning_are_worth_practising(target, heard, code):
    assert skills.sound_skill(target, heard) == code


def test_accent_only_skills_are_excluded_from_what_to_fix():
    for code in skills.ACCENT_ONLY:
        assert skills.is_accent_only(code)
        assert "correct Indian English" in skills.practice_hint(code)


def test_accent_differences_produce_no_pronunciation_tips():
    import feedback
    out = feedback.analyse("read", "I bought water.", "i bot waater")
    assert not [t for t in out["tips"] if "bought" in t or "water" in t], out["tips"]


def test_unknown_skill_names_still_land_somewhere_usable():
    assert skills.normalise(None) == skills.DEFAULT
    assert skills.normalise("completely made up") == skills.DEFAULT
    assert skills.normalise("grammar.articles") == "SYN.ARTICLE"
    assert skills.normalise("verb agreement") == "MORPH.AGREEMENT"
    assert skills.normalise("SYN.ARTICLE") == "SYN.ARTICLE"


# ----------------------------------------------------------------------------- G1 fair feedback
import pytest as _pytest  # noqa: E402


@_pytest.mark.parametrize("target,heard", [
    ("I study every day.", "i study everyday"),
    ("Please log in to the site.", "please login to the site"),
    ("It is a login page.", "it is a log in page"),
])
def test_word_boundary_differences_are_not_penalised(target, heard):
    """A reading transcribed with a different word split is correct, not a learner mistake."""
    r = f.analyse("read", target, heard)
    assert r["score"] == 100, [(w["target"], w["status"]) for w in r["words"]]
    assert all(w["status"] == "correct" for w in r["words"])


def test_genuine_misreadings_are_still_caught():
    r = f.analyse("read", "Think about three things", "sink about free things")
    assert r["score"] < 80
    assert any(w["status"] in ("wrong", "close") for w in r["words"])


def test_uncertain_audio_is_marked_unscored_not_zero():
    bad = f.analyse("read", "The quick brown fox jumps.", "zzz")
    assert bad["evaluation_status"] == "unscored" and "low_match" in bad["uncertainty_reasons"]
    empty = f.analyse("free", None, "")
    assert empty["evaluation_status"] == "unscored" and "no_speech" in empty["uncertainty_reasons"]


def test_good_answers_stay_scored_with_a_labelled_basis():
    r = f.analyse("read", "I like tea.", "I like tea")
    assert r["evaluation_status"] == "scored" and r["basis"] == "word_accuracy"
    assert f.analyse("build", None, "She goes to school.", "she goes to school")["basis"] == "exact_match"
    assert f.analyse("free", None, "I play cricket after school.")["basis"] == "rubric"
