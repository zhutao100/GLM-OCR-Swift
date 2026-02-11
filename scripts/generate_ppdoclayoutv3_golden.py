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
            "Generate an opt-in PP-DocLayoutV3 forward-pass golden fixture using Python/Transformers.\n\n"
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
            "  - a snapshot folder containing config.json/model.safetensors\n"
            "  - a 'models--org--name' folder (the script will auto-pick a snapshot)\n"
            "  - a folder containing a 'snapshots/' subfolder\n"
        ),
    )
    parser.add_argument(
        "--out",
        default=Path("Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_v1.json"),
        type=Path,
        help="Output JSON fixture path.",
    )
    parser.add_argument(
        "--device",
        default=None,
        choices=["cpu", "cuda", "mps"],
        help="Torch device (defaults to mps if available, else cuda if available, else cpu).",
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
    return (path / "config.json").is_file() and (path / "model.safetensors").exists()


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
        "Expected a folder containing at least: config.json, model.safetensors\n"
    )


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
    from transformers import PPDocLayoutV3ImageProcessorFast

    return PPDocLayoutV3ImageProcessorFast.from_pretrained(
        str(model_folder),
        local_files_only=True,
        trust_remote_code=False,
    )


def _load_model(model_folder: Path, *, torch_dtype: "torch.dtype"):
    from transformers import PPDocLayoutV3ForObjectDetection

    return PPDocLayoutV3ForObjectDetection.from_pretrained(
        str(model_folder),
        local_files_only=True,
        trust_remote_code=False,
        torch_dtype=torch_dtype,
    )


def main() -> None:
    args = _parse_args()

    model_folder: Path = _resolve_snapshot_folder(args.model_folder)
    out_path: Path = args.out.expanduser().resolve()

    config_path = model_folder / "config.json"
    weights_path = model_folder / "model.safetensors"
    for p in (config_path, weights_path):
        if not p.exists():
            raise SystemExit(f"Missing required file: {p}")

    config = _read_json(config_path)
    model_id = str(config.get("_name_or_path") or "PaddlePaddle/PP-DocLayoutV3_safetensors")

    num_queries = int(config.get("num_queries", 300))
    id2label = config.get("id2label", {})
    num_labels = int(config.get("num_labels") or len(id2label) or 25)

    # Lazy imports so this script can exist without deps installed.
    import torch
    import transformers

    device_str = args.device
    if device_str is None:
        if torch.backends.mps.is_available():
            device_str = "mps"
        elif torch.cuda.is_available():
            device_str = "cuda"
        else:
            device_str = "cpu"
    device = torch.device(device_str)

    torch_dtype = torch.float32
    if device.type == "mps":
        # MPS float32 support varies; float16 is the most reliable.
        torch_dtype = torch.float16

    image_processor = _load_image_processor(model_folder)
    model = _load_model(model_folder, torch_dtype=torch_dtype)
    model.eval()
    model = model.to(device)

    # Use the fixed processor size if present; otherwise fall back to 800.
    processor_cfg = getattr(image_processor, "size", None)
    if isinstance(processor_cfg, dict) and processor_cfg.get("height") and processor_cfg.get("width"):
        image_size = int(min(processor_cfg["height"], processor_cfg["width"]))
    else:
        image_size = 800

    image = _make_deterministic_image(image_size=image_size)
    inputs = image_processor(images=[image], return_tensors="pt")
    inputs = {k: v.to(device) for k, v in inputs.items()}
    # Ensure dtype matches the model weights (required on MPS).
    for key, value in list(inputs.items()):
        if torch.is_floating_point(value):
            inputs[key] = value.to(dtype=torch_dtype)

    pixel_values = inputs.get("pixel_values")
    if pixel_values is None or not torch.is_floating_point(pixel_values) or pixel_values.ndim != 4:
        raise SystemExit("Expected image processor to return float pixel_values with shape [B,C,H,W] or [B,H,W,C].")

    pixel_layout: str
    if int(pixel_values.shape[1]) == 3:
        pixel_layout = "NCHW_RGB"
    elif int(pixel_values.shape[-1]) == 3:
        pixel_layout = "NHWC_RGB"
    else:
        pixel_layout = "UNKNOWN"

    with torch.no_grad():
        outputs = model(**inputs)

    logits = getattr(outputs, "logits", None)
    pred_boxes = getattr(outputs, "pred_boxes", None)
    if logits is None or pred_boxes is None:
        raise SystemExit("Model outputs missing expected fields: logits and/or pred_boxes.")

    if logits.ndim != 3:
        raise SystemExit(f"Expected logits rank=3, got shape={tuple(logits.shape)}")
    if pred_boxes.ndim != 3 or int(pred_boxes.shape[-1]) != 4:
        raise SystemExit(f"Expected pred_boxes shape [B,Q,4], got shape={tuple(pred_boxes.shape)}")

    q_dim = int(logits.shape[1])
    c_dim = int(logits.shape[2])
    if q_dim != num_queries:
        num_queries = q_dim
    if c_dim != num_labels:
        num_labels = c_dim

    query_indices = [0, 1, 2, 10, 50, 100, 200, max(0, num_queries - 1)]
    query_indices = sorted(set(i for i in query_indices if 0 <= i < num_queries))
    class_indices = list(range(num_labels))

    logits_cpu = logits.detach().float().cpu()
    boxes_cpu = pred_boxes.detach().float().cpu()

    logits_slice: list[list[float]] = []
    boxes_slice: list[list[float]] = []
    for qi in query_indices:
        row = logits_cpu[0, qi, :].tolist()
        logits_slice.append([float(row[ci]) for ci in class_indices])
        box = boxes_cpu[0, qi, :].tolist()
        boxes_slice.append([float(v) for v in box])

    fixture: dict[str, Any] = {
        "metadata": {
            "fixture_version": "v1",
            "model_id": model_id,
            "snapshot_hash": _snapshot_hash_from_path(model_folder),
            "source": "python/transformers",
            "torch_version": torch.__version__,
            "transformers_version": transformers.__version__,
            "device": device_str,
            "dtype": str(torch_dtype).replace("torch.", ""),
            "pixel_layout": f"{pixel_layout}_{str(torch_dtype).replace('torch.', '')}",
            "generated_at": dt.datetime.now(dt.UTC).isoformat(),
        },
        "processor": {
            "image_size": image_size,
            "pixel_values_shape": [int(x) for x in pixel_values.shape],
            "do_resize": bool(getattr(image_processor, "do_resize", True)),
            "do_rescale": bool(getattr(image_processor, "do_rescale", True)),
            "rescale_factor": float(getattr(image_processor, "rescale_factor", 1.0 / 255.0)),
            "do_normalize": bool(getattr(image_processor, "do_normalize", True)),
            "image_mean": [float(x) for x in getattr(image_processor, "image_mean", [0.0, 0.0, 0.0])],
            "image_std": [float(x) for x in getattr(image_processor, "image_std", [1.0, 1.0, 1.0])],
        },
        "model": {
            "num_queries": num_queries,
            "num_labels": num_labels,
            "logits_shape": [int(x) for x in logits.shape],
            "pred_boxes_shape": [int(x) for x in pred_boxes.shape],
        },
        "query_indices": query_indices,
        "class_indices": class_indices,
        "logits_slice": logits_slice,
        "pred_boxes_slice": boxes_slice,
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(fixture, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote fixture: {out_path}")


if __name__ == "__main__":
    main()
