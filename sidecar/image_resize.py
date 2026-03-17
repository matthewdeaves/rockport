"""Auto-resize images for Nova Reel (target: 1280x720).

Supports five resize modes:
- scale: resize to exactly 1280x720 (may change aspect ratio)
- crop-center: scale to cover, then center-crop
- crop-top: scale to cover, then crop from top
- crop-bottom: scale to cover, then crop from bottom
- fit: scale to fit within 1280x720, pad remaining space
"""

import io

from PIL import Image

TARGET_WIDTH = 1280
TARGET_HEIGHT = 720

VALID_MODES = {"scale", "crop-center", "crop-top", "crop-bottom", "fit"}
VALID_PAD_COLORS = {"black", "white"}


def resize_image(
    image_bytes: bytes,
    mode: str = "scale",
    pad_color: str = "black",
) -> tuple[bytes, dict]:
    """Resize an image to 1280x720 using the specified mode.

    Args:
        image_bytes: Raw image bytes (PNG or JPEG).
        mode: Resize mode (scale, crop-center, crop-top, crop-bottom, fit).
        pad_color: Padding color for fit mode (black or white).

    Returns:
        Tuple of (resized_bytes, metadata_dict) where metadata_dict contains
        original_width, original_height, and mode.
    """
    img = Image.open(io.BytesIO(image_bytes))
    img.load()
    fmt = img.format  # preserve original format

    original_width, original_height = img.size
    metadata = {
        "original_width": original_width,
        "original_height": original_height,
        "mode": mode,
    }

    # Already correct size — no resize needed
    if img.size == (TARGET_WIDTH, TARGET_HEIGHT):
        return image_bytes, {}

    if mode == "scale":
        img = img.resize((TARGET_WIDTH, TARGET_HEIGHT), Image.LANCZOS)

    elif mode in ("crop-center", "crop-top", "crop-bottom"):
        img = _resize_and_crop(img, mode)

    elif mode == "fit":
        img = _resize_and_pad(img, pad_color)

    # Convert to RGB if needed (e.g., RGBA after resize)
    if fmt == "JPEG" and img.mode != "RGB":
        img = img.convert("RGB")

    buf = io.BytesIO()
    img.save(buf, format=fmt)
    return buf.getvalue(), metadata


def _resize_and_crop(img: Image.Image, mode: str) -> Image.Image:
    """Scale to cover target dimensions, then crop."""
    w, h = img.size
    # Scale factor to cover (both dimensions must be >= target)
    scale = max(TARGET_WIDTH / w, TARGET_HEIGHT / h)
    new_w = round(w * scale)
    new_h = round(h * scale)
    img = img.resize((new_w, new_h), Image.LANCZOS)

    # Crop to target
    if mode == "crop-center":
        left = (new_w - TARGET_WIDTH) // 2
        top = (new_h - TARGET_HEIGHT) // 2
    elif mode == "crop-top":
        left = (new_w - TARGET_WIDTH) // 2
        top = 0
    else:  # crop-bottom
        left = (new_w - TARGET_WIDTH) // 2
        top = new_h - TARGET_HEIGHT

    return img.crop((left, top, left + TARGET_WIDTH, top + TARGET_HEIGHT))


def _resize_and_pad(img: Image.Image, pad_color: str) -> Image.Image:
    """Scale to fit within target, pad remaining space."""
    w, h = img.size
    scale = min(TARGET_WIDTH / w, TARGET_HEIGHT / h)
    new_w = round(w * scale)
    new_h = round(h * scale)
    img = img.resize((new_w, new_h), Image.LANCZOS)

    bg_color = (0, 0, 0) if pad_color == "black" else (255, 255, 255)
    result = Image.new("RGB", (TARGET_WIDTH, TARGET_HEIGHT), bg_color)
    paste_x = (TARGET_WIDTH - new_w) // 2
    paste_y = (TARGET_HEIGHT - new_h) // 2

    # Handle alpha channel for pasting
    if img.mode in ("RGBA", "LA", "PA"):
        result.paste(img, (paste_x, paste_y), img)
    else:
        if img.mode != "RGB":
            img = img.convert("RGB")
        result.paste(img, (paste_x, paste_y))

    return result
