# Data Model: Complete Image Services

## New Pydantic Request Models

### InpaintRequest

| Field | Type | Default | Validation |
|---|---|---|---|
| image | str | required | data URI, via `_validate_stability_image` |
| prompt | str | required | min_length=0, max_length=10000 |
| mask | str \| None | None | data URI, validated as image if provided |
| grow_mask | int | 5 | ge=0, le=20 |
| negative_prompt | str \| None | None | max_length=10000 |
| seed | int \| None | None | ge=0, le=4,294,967,294 |
| output_format | str | "png" | png/jpeg/webp |
| style_preset | str \| None | None | validated against STABILITY_STYLE_PRESETS |

### EraseRequest

| Field | Type | Default | Validation |
|---|---|---|---|
| image | str | required | data URI |
| mask | str \| None | None | data URI |
| grow_mask | int | 5 | ge=0, le=20 |
| seed | int \| None | None | ge=0, le=4,294,967,294 |
| output_format | str | "png" | png/jpeg/webp |

### CreativeUpscaleRequest

| Field | Type | Default | Validation |
|---|---|---|---|
| image | str | required | data URI, max 1MP |
| prompt | str | required | min_length=0, max_length=10000 |
| creativity | float | 0.3 | ge=0.1, le=0.5 |
| negative_prompt | str \| None | None | max_length=10000 |
| seed | int \| None | None | ge=0, le=4,294,967,294 |
| output_format | str | "png" | png/jpeg/webp |
| style_preset | str \| None | None | validated |

### FastUpscaleRequest

| Field | Type | Default | Validation |
|---|---|---|---|
| image | str | required | data URI, 32-1536px per side, 1024-1048576 total pixels |
| output_format | str | "png" | png/jpeg/webp |

### SearchRecolorRequest

| Field | Type | Default | Validation |
|---|---|---|---|
| image | str | required | data URI |
| prompt | str | required | min_length=1, max_length=10000 |
| select_prompt | str | required | min_length=1, max_length=10000 |
| negative_prompt | str \| None | None | max_length=10000 |
| grow_mask | int | 5 | ge=0, le=20 |
| seed | int \| None | None | ge=0, le=4,294,967,294 |
| output_format | str | "png" | png/jpeg/webp |
| style_preset | str \| None | None | validated |

### StabilityOutpaintRequest

| Field | Type | Default | Validation |
|---|---|---|---|
| image | str | required | data URI |
| left | int | 0 | ge=0, le=2000 |
| right | int | 0 | ge=0, le=2000 |
| up | int | 0 | ge=0, le=2000 |
| down | int | 0 | ge=0, le=2000 |
| prompt | str \| None | None | max_length=10000 |
| creativity | float | 0.5 | ge=0.1, le=1.0 |
| seed | int \| None | None | ge=0, le=4,294,967,294 |
| output_format | str | "png" | png/jpeg/webp |
| style_preset | str \| None | None | validated |

Custom validation: at least one of left/right/up/down must be > 0.

## Updated Existing Models

### StructureRequest, SketchRequest, SearchReplaceRequest

Add field:
| Field | Type | Default | Validation |
|---|---|---|---|
| aspect_ratio | str \| None | None | validated against STABILITY_ASPECT_RATIOS (9 options) |

### ImageVariationRequest (Nova Canvas)

Add field:
| Field | Type | Default | Validation |
|---|---|---|---|
| negative_text | str \| None | None | max_length=1024 |

### OutpaintRequest (Nova Canvas)

Updates:
- Add `negative_text: str | None = None` (max_length=1024)
- Add validation on `quality` field: must be "standard" or "premium"
- Add `max_length=1024` on `mask_prompt` field

## Cost Entries (STABILITY_COSTS dict)

| Key | Cost |
|---|---|
| stability-inpaint | $0.04 |
| stability-erase | $0.04 |
| stability-creative-upscale | $0.06 |
| stability-fast-upscale | $0.04 |
| stability-search-recolor | $0.04 |
| stability-outpaint | $0.04 |

## Spend Logging

All new endpoints log to `LiteLLM_SpendLogs` + `LiteLLM_VerificationToken` via existing `db.log_image_spend(key_hash, model_name, cost, request_id)`.
