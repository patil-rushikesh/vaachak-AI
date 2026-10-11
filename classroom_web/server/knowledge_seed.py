"""Versioned starter curriculum, installed without creating or resetting user data."""
from evidence import now

UNITS = [
    ("MORPH.AGREEMENT", "He, she, it verbs", "In the simple present, most verbs take s with he, she or it: she goes, he likes. Use the base form with I, you, we and they.", "She goes to school."),
    ("MORPH.TENSE", "Talking about yesterday", "Some past-tense verbs are irregular: go becomes went and eat becomes ate. Learn these forms instead of adding ed.", "Yesterday I went home."),
    ("MORPH.PROGRESSIVE", "Actions happening now", "Use am, is or are with an ing verb for an action happening now. For states such as knowing something, usually use the simple form.", "I am reading now. I know this story."),
    ("SYN.ARTICLE", "A, an and the", "Use a before a consonant sound and an before a vowel sound. Use the when the listener can identify which thing you mean.", "a banana, an apple, the book on this desk"),
    ("SYN.PREPOSITION", "In, on, at for time", "Use at for a clock time, on for a named day, and in for a month or year.", "at nine on Monday in June"),
    ("SYN.QUESTION", "Asking a question", "Many questions put a helping verb before the subject. With does, the main verb keeps its base form.", "Where are you going? What does she want?"),
    ("PHON.TH", "Practising th", "For the th in think, let air pass gently between your tongue and teeth. The th in this also uses your voice. A transcript alone cannot establish how you made the sound.", "think, three, this, that"),
    ("PHON.VW", "Practising v and w", "For v, the top teeth touch the lower lip. For w, round your lips without touching your teeth to your lip. A transcript alone cannot establish a sound error.", "very, we, vine, wine"),
]


def install(conn) -> int:
    """Fixed IDs make repeated startup/CLI runs safe and preserve teacher notes."""
    before = conn.total_changes
    stamp = now()
    for code, title, body, example in UNITS:
        conn.execute(
            "INSERT INTO knowledge_units "
            "(id,skill_code,title,body,example,source,visibility,status,version,created_at,reviewed_at,published_at) "
            "VALUES(?,?,?,?,?,?,'public','published',1,?,?,?) ON CONFLICT DO NOTHING",
            (f"builtin-{code.lower()}-v1", code, title, body, example,
             "Vaachak starter curriculum v1", stamp, stamp, stamp),
        )
    return conn.total_changes - before
