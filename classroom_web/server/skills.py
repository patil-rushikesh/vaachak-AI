"""What a learner can be good or bad at, as a fixed vocabulary.

Every mistake the app records gets one skill code, so "what is this student weak at"
has a real answer instead of a pile of one-off sentences. Codes are DOMAIN.FEATURE:

    SYN   sentence building      MORPH  word endings and tense
    LEX   word choice            PHON   sounds
    FLU   saying enough          PROS   rhythm and stress

The feature list is built from the mistakes Marathi and Hindi speakers actually make in
English, not from a general grammar book.

ACCENT, NOT ERROR
Some features are how Indian English sounds, and are completely correct English. They are
listed in ACCENT_ONLY: the app may notice them, but must never score them down or show them
as something to fix. Retroflex t/d and long vowels are not mistakes. Neither is "prepone".
"""
from __future__ import annotations

# code -> (short label a student understands, domain, what to practise)
SKILLS: dict[str, tuple[str, str, str]] = {
    # ---- sentence building
    "SYN.ARTICLE": ("A, an and the", "Sentence building", "Putting a, an or the in the right place"),
    "SYN.PREPOSITION": ("In, on, at, about", "Sentence building", "Choosing the right small word after a verb"),
    "SYN.QUESTION": ("Asking questions", "Sentence building", "Word order in questions"),
    "SYN.WORDORDER": ("Word order", "Sentence building", "Putting the words in the usual order"),
    "SYN.AUXILIARY": ("Is, are, do, does", "Sentence building", "The small helping verb in a sentence"),
    # ---- word endings and tense
    "MORPH.AGREEMENT": ("He, she, it verbs", "Word endings", "Adding s with he, she and it"),
    "MORPH.TENSE": ("Past and present", "Word endings", "Choosing the right time of the verb"),
    "MORPH.PROGRESSIVE": ("-ing verbs", "Word endings", "When to use am, is or are with -ing"),
    "MORPH.PLURAL": ("One and many", "Word endings", "Making words plural the right way"),
    "MORPH.COMPARATIVE": ("Bigger, better", "Word endings", "Comparing two things"),
    # ---- word choice
    "LEX.CHOICE": ("Word choice", "Word choice", "Picking the word that fits"),
    "LEX.QUANTITY": ("Much, many, few", "Word choice", "Words for how much and how many"),
    # ---- saying enough
    "FLU.LENGTH": ("Full answers", "Speaking", "Answering in a whole sentence, not one word"),
    "FLU.CLARITY": ("Being understood", "Speaking", "Saying the sentence so it is clear"),
    # ---- sounds that change meaning (worth practising)
    "PHON.TH": ("The th sound", "Sounds", "think, three, this"),
    "PHON.VW": ("V and W", "Sounds", "very and we, vine and wine"),
    "PHON.ZS": ("Z and S", "Sounds", "zero, buzz, rose"),
    "PHON.SHS": ("Sh and S", "Sounds", "she, ship, wash"),
    "PHON.FP": ("F and P", "Sounds", "fan, coffee, phone"),
    "PHON.WORD": ("Word sounds", "Sounds", "Saying the whole word clearly"),
    # ---- accent only: noticed, never counted against anyone
    "PHON.RETROFLEX": ("Indian t and d", "Sounds", "This is correct Indian English"),
    "PHON.VOWEL": ("Vowel length", "Sounds", "This is correct Indian English"),
    "PROS.RHYTHM": ("Rhythm and stress", "Sounds", "This is correct Indian English"),
}

# Real English, just not British or American. Never penalised, never shown as a fix.
ACCENT_ONLY = {"PHON.RETROFLEX", "PHON.VOWEL", "PROS.RHYTHM"}

# Indian English words and phrases that are correct and must never be "corrected".
INDIAN_ENGLISH_OK = {
    "prepone", "do the needful", "out of station", "cousin brother", "cousin sister",
    "revert back", "kindly", "intimate", "passing out", "good name",
}

DEFAULT = "LEX.CHOICE"

# What the rule engine and older data called things, mapped onto the codes above.
_ALIASES: dict[str, str] = {
    "grammar.articles": "SYN.ARTICLE", "articles": "SYN.ARTICLE", "article": "SYN.ARTICLE",
    "grammar.simple_present_agreement": "MORPH.AGREEMENT", "simple present agreement": "MORPH.AGREEMENT",
    "verb agreement": "MORPH.AGREEMENT", "subject verb agreement": "MORPH.AGREEMENT", "agreement": "MORPH.AGREEMENT",
    "grammar.verbs": "MORPH.TENSE", "verbs": "MORPH.TENSE", "verb tense": "MORPH.TENSE", "tense": "MORPH.TENSE",
    "grammar.irregular_past": "MORPH.TENSE", "irregular past": "MORPH.TENSE", "past tense": "MORPH.TENSE",
    "grammar.continuous": "MORPH.PROGRESSIVE", "progressive": "MORPH.PROGRESSIVE", "continuous": "MORPH.PROGRESSIVE",
    "grammar.plurals": "MORPH.PLURAL", "plurals": "MORPH.PLURAL", "plural": "MORPH.PLURAL",
    "grammar.comparatives": "MORPH.COMPARATIVE", "comparatives": "MORPH.COMPARATIVE", "comparative": "MORPH.COMPARATIVE",
    "grammar.prepositions": "SYN.PREPOSITION", "prepositions": "SYN.PREPOSITION", "preposition": "SYN.PREPOSITION",
    "grammar.questions": "SYN.QUESTION", "questions": "SYN.QUESTION", "question form": "SYN.QUESTION",
    "grammar.word_order": "SYN.WORDORDER", "word order": "SYN.WORDORDER",
    "grammar.quantity": "LEX.QUANTITY", "quantity": "LEX.QUANTITY",
    "grammar.auxiliary": "SYN.AUXILIARY", "auxiliary": "SYN.AUXILIARY",
    "word choice": "LEX.CHOICE", "vocabulary": "LEX.CHOICE", "lexis": "LEX.CHOICE",
    "pronunciation": "PHON.WORD", "fluency": "FLU.LENGTH",
}


def normalise(raw: str | None) -> str:
    """Turn anything a model or an old rule gave us into a real skill code."""
    if not raw:
        return DEFAULT
    key = str(raw).strip()
    if key in SKILLS:
        return key
    low = key.lower().replace("_", " ").strip()
    if low in _ALIASES:
        return _ALIASES[low]
    upper = key.upper().replace(" ", ".").replace("-", ".")
    if upper in SKILLS:
        return upper
    for alias, code in _ALIASES.items():  # "simple present agreement rule" still finds its skill
        if alias in low:
            return code
    return DEFAULT


def label(code: str) -> str:
    return SKILLS.get(code, SKILLS[DEFAULT])[0]


def domain(code: str) -> str:
    return SKILLS.get(code, SKILLS[DEFAULT])[1]


def practice_hint(code: str) -> str:
    return SKILLS.get(code, SKILLS[DEFAULT])[2]


def is_accent_only(code: str) -> bool:
    return code in ACCENT_ONLY


def describe(code: str) -> dict:
    return {"code": code, "label": label(code), "domain": domain(code),
            "hint": practice_hint(code), "accent_only": is_accent_only(code)}


# Which sound a swapped word points at. Checked in order; first hit wins.
# Each entry: (letters in the word the learner was meant to say, letters heard instead, code)
_SOUND_PAIRS: list[tuple[str, str, str]] = [
    ("th", "t", "PHON.TH"), ("th", "d", "PHON.TH"), ("th", "f", "PHON.TH"), ("th", "s", "PHON.TH"),
    ("v", "w", "PHON.VW"), ("w", "v", "PHON.VW"),
    ("z", "s", "PHON.ZS"), ("z", "j", "PHON.ZS"),
    ("sh", "s", "PHON.SHS"), ("s", "sh", "PHON.SHS"),
    ("f", "p", "PHON.FP"), ("ph", "p", "PHON.FP"),
]


def _sound_key(word: str) -> str:
    """A rough 'how it sounds' key, so spelling differences do not look like mistakes.

    The recogniser may write the same sound as "bought" or "bot", and an Indian accent may
    stretch a vowel. Both collapse to the same key, so neither is reported as an error.
    """
    w = word.lower().strip()
    for a, b in (("ough", "o"), ("augh", "o"), ("gh", ""), ("sch", "sk"), ("ch", "\x01"),
                 ("ck", "k"), ("ph", "f"), ("qu", "kw"), ("wh", "w"), ("kn", "n"), ("wr", "r"),
                 ("c", "k"), ("\x01", "ch"), ("x", "ks")):
        w = w.replace(a, b)
    while len(w) > 2 and w[-1] in "ewh":   # silent tail: have/no(w)/oh
        w = w[:-1]
    out = []
    for ch in w:
        if ch in "aeiou":
            if not out or out[-1] != "a":
                out.append("a")          # every vowel run becomes one neutral vowel
        elif not out or out[-1] != ch:
            out.append(ch)               # collapse doubled consonants
    return "".join(out)


def sound_skill(target: str, heard: str) -> str | None:
    """Which sound to practise, given the word wanted and the word heard.

    Returns None when the difference is accent or spelling rather than a sound mistake, so a
    learner is never told to fix something that was already correct. The key is deliberately
    loose: when in doubt it stays quiet, because wrongly telling a learner their correct
    speech is wrong costs far more than missing one real slip.
    """
    t, h = (target or "").lower().strip(), (heard or "").lower().strip()
    if not t or not h or t == h:
        return None
    for a, b, code in _SOUND_PAIRS:          # a contrast that changes meaning comes first
        if a in t and b in h and a not in h:
            return code
    if _sound_key(t) == _sound_key(h):       # same sounds, different spelling or accent
        return None
    return "PHON.WORD"
