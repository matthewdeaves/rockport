"""Nova Reel prompt validation rules.

Rejects prompts that will produce poor results due to known model pitfalls:
- Negation words (Nova Reel interprets negation subjects as positive signals)
- Camera keywords before the final clause (must be at the end)
- Prompts shorter than 50 characters (too sparse, causes warping)
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

MIN_PROMPT_LENGTH = 50


def validate_nova_reel_prompt(prompt: str, shot_number: int | None = None) -> dict | None:
    """Validate a Nova Reel prompt against quality rules.

    Args:
        prompt: The prompt text to validate.
        shot_number: 1-indexed shot number for multi-shot requests (None for single-shot).

    Returns:
        Error dict matching contracts/video-prompt-validation.md format, or None if valid.
    """
    # Check minimum length first
    if len(prompt) < MIN_PROMPT_LENGTH:
        return {
            "error": {
                "type": "prompt_validation_error",
                "rule": "min_length",
                "message": (
                    f"Prompt is {len(prompt)} characters (minimum {MIN_PROMPT_LENGTH}). "
                    "Short prompts give the model too much freedom, resulting in warping "
                    "and morphing artefacts. Add more detail describing the subject, "
                    "action, environment, and style."
                ),
                "shot": shot_number,
            }
        }

    # Check for negation words (strip apostrophes so don't→dont, can't→cant, etc.)
    normalized = prompt.replace("'", "").replace("\u2019", "")  # straight + curly apostrophe
    match = _NEGATION_PATTERN.search(normalized)
    if match:
        word = match.group(0)
        # Show the original text around the match position for a helpful error
        pos = match.start()
        # Find the corresponding word in the original prompt for display
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
        }

    # Check camera keyword positioning
    error = _check_camera_position(prompt, shot_number)
    if error:
        return error

    return None


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
    """Check that camera keywords appear only after the last comma or period.

    Trailing punctuation is stripped before finding the separator, so a prompt
    ending with "dolly forward." correctly treats "dolly forward" as the final
    clause (the trailing period is not a clause boundary).
    """
    # Strip trailing punctuation so "..., dolly forward." doesn't treat
    # the trailing period as the clause boundary
    stripped = prompt.rstrip(" .,;:!?")

    # Find the position of the last comma or period in the stripped prompt
    last_sep = max(stripped.rfind(","), stripped.rfind("."))

    if last_sep == -1:
        # No comma or period — the entire prompt is one clause.
        # Camera keywords anywhere are fine (there's no "before final clause").
        return None

    # Text before the final clause
    before_final = stripped[:last_sep].lower()

    # Check multi-word phrases first
    for phrase in _CAMERA_PHRASES:
        if phrase in before_final:
            return _camera_error(phrase, shot_number)

    # Check single words (pre-compiled patterns)
    for i, pattern in enumerate(_CAMERA_WORD_PATTERNS):
        if pattern.search(before_final):
            return _camera_error(_CAMERA_WORDS[i], shot_number)

    return None


def _camera_error(keyword: str, shot_number: int | None) -> dict:
    """Build a camera position error response."""
    return {
        "error": {
            "type": "prompt_validation_error",
            "rule": "camera_position",
            "message": (
                f"Camera keyword '{keyword}' found before the final clause. "
                "Camera motion keywords must be placed at the end of the prompt, "
                f"after the last comma or period. Move '{keyword}' to the end."
            ),
            "shot": shot_number,
        }
    }
