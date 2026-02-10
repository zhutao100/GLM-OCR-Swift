#!/usr/bin/env python3

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
from pathlib import Path
from typing import Any


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate an opt-in GLM-OCR forward-pass golden fixture using Python/Transformers.\n\n"
            "This script is developer-only and is not run by CI."
        ),
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument(
        "--model-folder",
        required=True,
        type=Path,
        help=(
            "Path to a local Hugging Face model folder.\n"
            "Accepted inputs:\n"
            "  - a snapshot folder containing config.json/tokenizer.json/model.safetensors\n"
            "  - a 'models--org--name' folder (the script will auto-pick a snapshot)\n"
            "  - a folder containing a 'snapshots/' subfolder\n"
        ),
    )
    parser.add_argument(
        "--out",
        default=Path("Tests/GLMOCRAdapterTests/Fixtures/glmocr_forward_golden_v1.json"),
        type=Path,
        help="Output JSON fixture path.",
    )
    parser.add_argument("--prompt", default=" OCR:", help="Prompt suffix to append after the image placeholder tokens.")
    parser.add_argument("--topk", default=5, type=int, help="Top-k token IDs to store at the last position.")
    parser.add_argument(
        "--device",
        default=None,
        choices=["cpu", "mps"],
        help="Torch device (defaults to mps if available, else cpu).",
    )
    return parser.parse_args()


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _snapshot_hash_from_path(model_folder: Path) -> str | None:
    # Typical HF cache layout:
    #   .../models--org--name/snapshots/<hash>/
    m = re.search(r"/snapshots/([0-9a-f]{12,64})(/|$)", str(model_folder))
    return m.group(1) if m else None


def _looks_like_snapshot_folder(path: Path) -> bool:
    return (
        (path / "config.json").is_file()
        and (path / "tokenizer.json").is_file()
        and (path / "model.safetensors").exists()
    )


def _resolve_snapshot_folder(model_folder: Path) -> Path:
    model_folder = model_folder.expanduser().resolve()

    if model_folder.is_file():
        model_folder = model_folder.parent

    if _looks_like_snapshot_folder(model_folder):
        return model_folder

    snapshots_dir = model_folder / "snapshots"
    if snapshots_dir.is_dir():
        candidates = [d for d in snapshots_dir.iterdir() if d.is_dir() and _looks_like_snapshot_folder(d)]
        if candidates:
            return max(candidates, key=lambda d: (d.stat().st_mtime, d.name))

    if model_folder.name == "snapshots" and model_folder.is_dir():
        candidates = [d for d in model_folder.iterdir() if d.is_dir() and _looks_like_snapshot_folder(d)]
        if candidates:
            return max(candidates, key=lambda d: (d.stat().st_mtime, d.name))

    raise SystemExit(
        "Could not resolve a valid snapshot folder from --model-folder.\n"
        f"Given: {model_folder}\n"
        "Expected a folder containing at least: config.json, tokenizer.json, model.safetensors\n"
    )


def _lcg_unique_indices(vocab_size: int, *, count: int, seed: int, exclude: set[int]) -> list[int]:
    a = 1103515245
    c = 12345
    m = 2**31
    x = seed & (m - 1)

    out: list[int] = []
    seen = set(exclude)
    while len(out) < count:
        x = (a * x + c) % m
        idx = int(x % vocab_size)
        if idx in seen:
            continue
        out.append(idx)
        seen.add(idx)
    return out


def _make_deterministic_image(*, image_size: int):
    import numpy as np
    from PIL import Image

    h = int(image_size)
    w = int(image_size)
    if h <= 0 or w <= 0:
        raise ValueError(f"Invalid image_size: {image_size}")

    xs = np.arange(w, dtype=np.int64)
    ys = np.arange(h, dtype=np.int64)
    xx = np.broadcast_to(xs[None, :], (h, w))
    yy = np.broadcast_to(ys[:, None], (h, w))

    w_denom = max(w - 1, 1)
    h_denom = max(h - 1, 1)
    b_denom = max((w - 1) + (h - 1), 1)

    r = (xx * 255) // w_denom
    g = (yy * 255) // h_denom
    b = ((xx + yy) * 255) // b_denom

    rgb = np.stack([r, g, b], axis=-1).astype(np.uint8)
    return Image.fromarray(rgb)


def _load_image_processor(model_folder: Path):
    from transformers import AutoImageProcessor

    return AutoImageProcessor.from_pretrained(
        str(model_folder),
        local_files_only=True,
        trust_remote_code=False,
    )


def _load_tokenizer(model_folder: Path):
    from transformers import AutoTokenizer

    return AutoTokenizer.from_pretrained(
        str(model_folder),
        local_files_only=True,
        trust_remote_code=False,
        use_fast=True,
    )


def _load_model(model_folder: Path, *, torch_dtype: "torch.dtype"):
    import torch

    try:
        from transformers import GlmOcrForConditionalGeneration

        return GlmOcrForConditionalGeneration.from_pretrained(
            str(model_folder),
            local_files_only=True,
            trust_remote_code=False,
            torch_dtype=torch_dtype,
        )
    except Exception:
        # Fallback for older Transformers versions.
        from transformers import AutoModelForVision2Seq

        return AutoModelForVision2Seq.from_pretrained(
            str(model_folder),
            local_files_only=True,
            trust_remote_code=False,
            torch_dtype=torch_dtype,
        )


def _require_token_id(tokenizer, token: str) -> int:
    token_id = tokenizer.convert_tokens_to_ids(token)
    if token_id is None or token_id == tokenizer.unk_token_id:
        raise RuntimeError(f"Token not found in tokenizer vocab: {token!r}")
    return int(token_id)


def _normalize_eos_id(eos_token_id: Any) -> int:
    if isinstance(eos_token_id, list) and eos_token_id:
        return int(eos_token_id[-1])
    return int(eos_token_id)


def _forward_logits(
    model,
    *,
    input_ids,
    pixel_values,
    image_grid_thw,
    device: "torch.device",
) -> "torch.Tensor":
    import torch

    input_ids = input_ids.to(device)
    pixel_values = pixel_values.to(device)
    image_grid_thw = image_grid_thw.to(device)

    with torch.no_grad():
        out = model(input_ids=input_ids, pixel_values=pixel_values, image_grid_thw=image_grid_thw)
    logits = out.logits
    if logits is None:
        raise RuntimeError("Model output has no 'logits' field.")
    return logits


def main() -> None:
    args = _parse_args()

    model_folder: Path = _resolve_snapshot_folder(args.model_folder)
    out_path: Path = args.out.expanduser().resolve()

    config_path = model_folder / "config.json"
    tokenizer_path = model_folder / "tokenizer.json"
    weights_path = model_folder / "model.safetensors"
    for p in (config_path, tokenizer_path, weights_path):
        if not p.exists():
            raise SystemExit(f"Missing required file: {p}")

    config = _read_json(config_path)
    text_cfg = config.get("text_config", {})
    vision_cfg = config.get("vision_config", {})

    vocab_size = int(text_cfg.get("vocab_size", 59392))
    pad_id = int(text_cfg.get("pad_token_id", 0))
    image_size = int(vision_cfg.get("image_size", 336))
    patch_size = int(vision_cfg.get("patch_size", 14))
    merge_size = int(vision_cfg.get("spatial_merge_size", 2))
    temporal_patch_size = int(vision_cfg.get("temporal_patch_size", 2))

    # Lazy imports so this script can be present without deps installed.
    import torch

    device_str = args.device
    if device_str is None:
        device_str = "mps" if torch.backends.mps.is_available() else "cpu"
    device = torch.device(device_str)

    # Prefer BF16 (matches the released checkpoint) but fall back if unsupported.
    torch_dtype = torch.bfloat16
    if device.type == "mps":
        # MPS support varies across torch versions; float16 is the most reliable.
        torch_dtype = torch.float16

    image_processor = _load_image_processor(model_folder)
    tokenizer = _load_tokenizer(model_folder)
    model = _load_model(model_folder, torch_dtype=torch_dtype)
    model.eval()
    model.to(device)

    eos_id = _normalize_eos_id(getattr(tokenizer, "eos_token_id", None))

    token_ids = {
        "pad_id": pad_id,
        "eos_id": eos_id,
        "gmask_id": _require_token_id(tokenizer, "[gMASK]"),
        "sop_id": _require_token_id(tokenizer, "<sop>"),
        "system_id": _require_token_id(tokenizer, "<|system|>"),
        "user_id": _require_token_id(tokenizer, "<|user|>"),
        "assistant_id": _require_token_id(tokenizer, "<|assistant|>"),
        "begin_image_id": _require_token_id(tokenizer, "<|begin_of_image|>"),
        "image_id": _require_token_id(tokenizer, "<|image|>"),
        "end_image_id": _require_token_id(tokenizer, "<|end_of_image|>"),
    }

    image = _make_deterministic_image(image_size=image_size)
    vision_inputs = image_processor(images=image, return_tensors="pt")
    if "pixel_values" not in vision_inputs or "image_grid_thw" not in vision_inputs:
        raise RuntimeError("Processor did not return 'pixel_values' and 'image_grid_thw'.")

    pixel_values = vision_inputs["pixel_values"]
    image_grid_thw = vision_inputs["image_grid_thw"]

    num_patches = int(image_grid_thw[0].prod().item())
    num_image_tokens = num_patches // (merge_size**2)

    prompt: str = args.prompt
    prompt_token_ids: list[int] = tokenizer.encode(prompt, add_special_tokens=False)
    input_ids_list: list[int] = [
        token_ids["gmask_id"],
        token_ids["sop_id"],
        token_ids["user_id"],
        token_ids["begin_image_id"],
        *([token_ids["image_id"]] * num_image_tokens),
        token_ids["end_image_id"],
        *prompt_token_ids,
    ]
    seq_len = len(input_ids_list)

    input_ids = torch.tensor(input_ids_list, dtype=torch.int64).reshape(1, -1)
    logits = _forward_logits(
        model,
        input_ids=input_ids,
        pixel_values=pixel_values.to(dtype=torch_dtype),
        image_grid_thw=image_grid_thw,
        device=device,
    )

    logits = logits[0].to(dtype=torch.float32).cpu()

    topk = int(args.topk)
    topk_ids = torch.topk(logits[-1], k=topk).indices.tolist()

    base_vocab_indices = set(range(16))
    base_vocab_indices.update(token_ids.values())
    lcg = _lcg_unique_indices(vocab_size, count=16, seed=12345, exclude=base_vocab_indices)
    vocab_indices = sorted(base_vocab_indices.union(lcg))

    positions = [
        4,
        4 + (num_image_tokens // 2),
        seq_len - 1,
    ]

    logits_slice: list[list[float]] = []
    for pos in positions:
        row = logits[pos][vocab_indices].tolist()
        logits_slice.append([float(x) for x in row])

    generated_at = dt.datetime.now(tz=dt.UTC).isoformat()
    snapshot_hash = _snapshot_hash_from_path(model_folder)

    fixture: dict[str, Any] = {
        "metadata": {
            "fixture_version": "v1",
            "model_id": "zai-org/GLM-OCR",
            "snapshot_hash": snapshot_hash,
            "source": "python-transformers",
            "pixel_layout": "patch_packed",
            "generated_at": generated_at,
        },
        "config": {
            "vocab_size": vocab_size,
            "image_size": image_size,
            "patch_size": patch_size,
            "merge_size": merge_size,
            "temporal_patch_size": temporal_patch_size,
        },
        "derived": {
            "num_image_tokens": num_image_tokens,
            "seq_len": seq_len,
        },
        "token_ids": token_ids,
        "prompt": prompt,
        "topk_last": [int(x) for x in topk_ids],
        "positions": [int(x) for x in positions],
        "vocab_indices": [int(x) for x in vocab_indices],
        "logits_slice": logits_slice,
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(fixture, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"OK: wrote {out_path}")
    print(f"Device: {device.type}, dtype: {torch_dtype}")
    if snapshot_hash:
        print(f"Snapshot: {snapshot_hash}")


if __name__ == "__main__":
    main()
