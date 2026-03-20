"""Nova Reel prompt validation rules.

- Negation words: rejected (Nova Reel interprets them as positive signals)
- Camera keywords in the middle of prompts: warning (best at start or end)
"""

import re

# --- Negation Detection ---
#
# Strategy: strip apostrophes from the prompt, then check for whole words.
# This catches all punctuation variants naturally:
#   don't / dont / Don't  →  "dont"  (matched)
#   can't / cant          →  "cant"  (matched)
#   won't / wont          →  "wont"  (matched)
#   "do not"              →  "not"   (matched as standalone word)
#
# Word boundaries (\b) prevent false positives on substrings:
#   Nottingham, knotted, another, notable, notion, annotate — all safe.

_NEGATION_WORDS = [
    "no", "not", "never", "without", "avoid",
    # Contracted negations (apostrophe-stripped forms)
    "dont", "cant", "wont", "isnt", "doesnt",
    "shouldnt", "arent", "wasnt", "werent", "wouldnt",
    "couldnt", "hasnt", "havent", "hadnt", "neednt",
]

_NEGATION_PATTERN = re.compile(
    r"\b(" + "|".join(re.escape(w) for w in _NEGATION_WORDS) + r")\b",
    re.IGNORECASE,
)

# --- Camera Keywords ---
# Pre-compiled at module level for efficiency.

_CAMERA_PHRASES = ["following shot", "static shot"]
_CAMERA_WORDS = ["dolly", "pan", "tilt", "track", "orbit", "zoom"]

_CAMERA_WORD_PATTERNS = [
    re.compile(r"\b" + re.escape(w) + r"\b", re.IGNORECASE)
    for w in _CAMERA_WORDS
]


def validate_nova_reel_prompt(prompt: str, shot_number: int | None = None) -> tuple[dict | None, list[dict]]:
    """Validate a Nova Reel prompt against quality rules.

    Args:
        prompt: The prompt text to validate.
        shot_number: 1-indexed shot number for multi-shot requests (None for single-shot).

    Returns:
        (error, warnings) tuple. error is a dict if the prompt must be rejected,
        None if acceptable. warnings is a list of advisory dicts (non-blocking).
    """
    # Check for negation words (strip apostrophes so don't→dont, can't→cant, etc.)
    normalized = prompt.replace("'", "").replace("\u2019", "")  # straight + curly apostrophe
    match = _NEGATION_PATTERN.search(normalized)
    if match:
        word = match.group(0)
        pos = match.start()
        original_word = _find_original_word(prompt, pos, word)
        return {
            "error": {
                "type": "prompt_validation_error",
                "rule": "negation",
                "message": (
                    f"Nova Reel prompt contains negation word '{original_word}'. "
                    "Nova Reel interprets negation subjects as positive signals — describe "
                    "only what you want to see. Rephrase without negation words."
                ),
                "shot": shot_number,
            }
        }, []

    # Check camera keyword positioning (advisory, not blocking)
    warnings = []
    warning = _check_camera_position(prompt, shot_number)
    if warning:
        warnings.append(warning)

    return None, warnings


def _find_original_word(original: str, approx_pos: int, normalized_word: str) -> str:
    """Find the original word in the prompt near the position from the normalized version.

    Handles the offset shift from apostrophe stripping. Falls back to the
    normalized form if we can't find a match.
    """
    # Scan forward from approx_pos in the original, allowing for apostrophes
    # that were stripped. Look for the word with apostrophes reinserted.
    search_start = max(0, approx_pos - 2)
    search_end = min(len(original), approx_pos + len(normalized_word) + 5)
    region = original[search_start:search_end]

    # Try to find a word in the region that normalizes to our match
    for m in re.finditer(r"\S+", region):
        candidate = m.group(0).strip(".,;:!?")
        if candidate.replace("'", "").replace("\u2019", "").lower() == normalized_word.lower():
            return candidate

    return normalized_word


def _check_camera_position(prompt: str, shot_number: int | None) -> dict | None:
    """Check that camera keywords appear only at the start or end of the prompt.

    AWS recommends placing camera movement descriptions at the start or end
    of the prompt for best results. Keywords in the middle (between the first
    and last clause separators) produce a warning.
    """
    stripped = prompt.rstrip(" .,;:!?")

    # Find all comma/period positions to identify clause boundaries
    separators = [i for i, c in enumerate(stripped) if c in (",", ".")]

    if len(separators) < 2:
        # 0 or 1 separators — no middle section exists, so camera keywords
        # are necessarily at the start or end. Nothing to reject.
        return None

    first_sep = separators[0]
    last_sep = separators[-1]

    # Middle text is between the first and last separators
    middle = stripped[first_sep + 1:last_sep].lower()

    # Check multi-word phrases first
    for phrase in _CAMERA_PHRASES:
        if phrase in middle:
            return _camera_warning(phrase, shot_number)

    # Check single words (pre-compiled patterns)
    for i, pattern in enumerate(_CAMERA_WORD_PATTERNS):
        if pattern.search(middle):
            return _camera_warning(_CAMERA_WORDS[i], shot_number)

    return None


def _camera_warning(keyword: str, shot_number: int | None) -> dict:
    """Build a camera position warning (advisory, non-blocking)."""
    return {
        "type": "prompt_quality_warning",
        "rule": "camera_position",
        "message": (
            f"Camera keyword '{keyword}' found in the middle of the prompt. "
            "For best results, place camera motion keywords at the start or end."
        ),
        "shot": shot_number,
    }
