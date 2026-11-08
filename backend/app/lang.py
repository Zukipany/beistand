"""English by default, German when the phone is set to German. Both texts side by side."""


def norm(lang: str | None) -> str:
    return "de" if (lang or "").lower().startswith("de") else "en"


def tr(lang: str | None, en: str, de: str) -> str:
    return de if norm(lang) == "de" else en


def name(lang: str | None) -> str:
    """For LLM prompts: 'Antworte auf Englisch' reads better than a code."""
    return "German" if norm(lang) == "de" else "English"
