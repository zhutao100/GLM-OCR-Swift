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
    parser.add_argument(
        "--include-intermediates",
        action="store_true",
        help="Include intermediate tensor samples (fixture v3) to localize parity drift.",
    )
    parser.add_argument(
        "--include-decoder-intermediates",
        action="store_true",
        help=(
            "Include decoder (layer 0) internal tensor samples (fixture v4) to localize drift inside the decoder.\n"
            "Implies --include-intermediates."
        ),
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


def _nchw_to_nhwc(x: "torch.Tensor") -> "torch.Tensor":
    if x.ndim != 4:
        raise ValueError(f"Expected rank-4 NCHW tensor, got shape={tuple(x.shape)}")
    return x.permute(0, 2, 3, 1).contiguous()


def _stats(x: "torch.Tensor") -> dict[str, float]:
    xf = x.detach().float()
    return {
        "mean": float(xf.mean().item()),
        "std": float(xf.std(unbiased=False).item()),
        "min": float(xf.min().item()),
        "max": float(xf.max().item()),
    }


def _stats_from_values(values: list[float]) -> dict[str, float]:
    import math

    finite = [float(v) for v in values if math.isfinite(v)]
    if not finite:
        return {"mean": 0.0, "std": 0.0, "min": 0.0, "max": 0.0}

    mean = sum(finite) / len(finite)
    var = sum((v - mean) * (v - mean) for v in finite) / len(finite)
    std = math.sqrt(var)
    return {"mean": float(mean), "std": float(std), "min": float(min(finite)), "max": float(max(finite))}


def _unique_in_bounds(pairs: list[tuple[int, int]], *, h: int, w: int) -> list[tuple[int, int]]:
    seen: set[tuple[int, int]] = set()
    out: list[tuple[int, int]] = []
    for y, x in pairs:
        if 0 <= y < h and 0 <= x < w and (y, x) not in seen:
            seen.add((y, x))
            out.append((y, x))
    return out


def _unique_indices(indices: list[int], *, length: int) -> list[int]:
    seen: set[int] = set()
    out: list[int] = []
    for i in indices:
        if 0 <= i < length and i not in seen:
            seen.add(i)
            out.append(i)
    return out


def _sample_scalar(x: "torch.Tensor", index: list[int]) -> float:
    xi = x
    for i in index:
        xi = xi[int(i)]
    return float(xi.detach().float().cpu().item())


def _sample_nhwc(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [B,H,W,C]
    b, h, w, c = [int(v) for v in x.shape]
    if b < 1:
        return []

    batches = _unique_indices([0, 1, max(b - 1, 0)], length=b)
    spatial = _unique_in_bounds(
        [
            (0, 0),
            (0, 1),
            (1, 0),
            (h // 2, w // 2),
            (max(h - 2, 0), max(w - 2, 0)),
        ],
        h=h,
        w=w,
    )
    channels = _unique_indices([0, 1, 2, 7, 15, 31], length=c)

    samples: list[dict[str, Any]] = []
    for bi in batches:
        for y, x0 in spatial:
            for ch in channels:
                idx = [bi, y, x0, ch]
                samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _sample_bsc(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [B,S,C]
    b, s, c = [int(v) for v in x.shape]
    if b < 1:
        return []

    seq = _unique_indices([0, 1, 2, 10, 49, 100, max(s - 1, 0)], length=s)
    channels = _unique_indices([0, 1, 2, 7, 15, 31], length=c)

    samples: list[dict[str, Any]] = []
    for si in seq:
        for ch in channels:
            idx = [0, si, ch]
            samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _sample_bsc_wide(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [B,S,C]
    b, s, c = [int(v) for v in x.shape]
    if b < 1:
        return []

    seq = _unique_indices([0, 1, 2, 10, 49, 100, max(s - 1, 0)], length=s)
    channels = _unique_indices(
        [0, 1, 2, 7, 15, 31, 32, 33, 63, 64, 95, 96, 127, 128, 159, 160, 191, 192, 223, 224, max(c - 1, 0)],
        length=c,
    )

    samples: list[dict[str, Any]] = []
    for si in seq:
        for ch in channels:
            idx = [0, si, ch]
            samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _sample_c(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [C]
    c = int(x.shape[0])
    channels = _unique_indices([0, 1, 2, 7, 15, 31, max(c - 1, 0)], length=c)

    samples: list[dict[str, Any]] = []
    for ch in channels:
        idx = [ch]
        samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _sample_bs4(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [B,S,4]
    b, s, c = [int(v) for v in x.shape]
    if b < 1:
        return []
    if c != 4:
        raise ValueError(f"Expected last dim=4 for bs4 sampler, got shape={tuple(x.shape)}")

    seq = _unique_indices([0, 1, 2, 10, 49, 100, max(s - 1, 0)], length=s)
    samples: list[dict[str, Any]] = []
    for si in seq:
        for ch in range(4):
            idx = [0, si, ch]
            samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _sample_bs1(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [B,S,1]
    b, s, c = [int(v) for v in x.shape]
    if b < 1:
        return []
    if c != 1:
        raise ValueError(f"Expected last dim=1 for bs1 sampler, got shape={tuple(x.shape)}")

    seq = _unique_indices([0, 1, 2, 10, 49, 100, max(s - 1, 0)], length=s)
    samples: list[dict[str, Any]] = []
    for si in seq:
        idx = [0, si, 0]
        samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _sample_enc_outputs_class(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [B,S,num_labels]
    b, s, c = [int(v) for v in x.shape]
    if b < 1:
        return []

    seq = _unique_indices([0, 1, 2, 10, 49, 100, max(s - 1, 0)], length=s)
    classes = _unique_indices([0, 1, 2, 5, 10, max(c - 1, 0)], length=c)

    samples: list[dict[str, Any]] = []
    for si in seq:
        for cl in classes:
            idx = [0, si, cl]
            samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _sample_decoder_offsets(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [B,Q,H,L,P,2]
    b, q, h, l, p, c = [int(v) for v in x.shape]
    if b < 1:
        return []
    if c != 2:
        raise ValueError(f"Expected last dim=2 for decoder offsets sampler, got shape={tuple(x.shape)}")

    queries = _unique_indices([0, 1, 2], length=q)
    heads = _unique_indices([0], length=h)
    levels = list(range(l))
    points = list(range(p))
    coords = [0, 1]

    samples: list[dict[str, Any]] = []
    for qi in queries:
        for hi in heads:
            for li in levels:
                for pi in points:
                    for ci in coords:
                        idx = [0, qi, hi, li, pi, ci]
                        samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _sample_decoder_attention_weights(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [B,Q,H,L,P]
    b, q, h, l, p = [int(v) for v in x.shape]
    if b < 1:
        return []

    queries = _unique_indices([0, 1, 2], length=q)
    heads = _unique_indices([0], length=h)
    levels = list(range(l))
    points = list(range(p))

    samples: list[dict[str, Any]] = []
    for qi in queries:
        for hi in heads:
            for li in levels:
                for pi in points:
                    idx = [0, qi, hi, li, pi]
                    samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _sample_nqp2(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [N,Q,P,2]
    n, q, p, c = [int(v) for v in x.shape]
    if n < 1:
        return []
    if c != 2:
        raise ValueError(f"Expected last dim=2 for nqp2 sampler, got shape={tuple(x.shape)}")

    ns = _unique_indices([0, 1, max(n - 1, 0)], length=n)
    queries = _unique_indices([0, 1, 2, 49, max(q - 1, 0)], length=q)
    points = _unique_indices([0, 1, max(p - 1, 0)], length=p)
    coords = [0, 1]

    samples: list[dict[str, Any]] = []
    for ni in ns:
        for qi in queries:
            for pi in points:
                for ci in coords:
                    idx = [ni, qi, pi, ci]
                    samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _sample_nqpc(x: "torch.Tensor") -> list[dict[str, Any]]:
    # x: [N,Q,P,C]
    n, q, p, c = [int(v) for v in x.shape]
    if n < 1:
        return []

    ns = _unique_indices([0, 1, max(n - 1, 0)], length=n)
    queries = _unique_indices([0, 1, 2, 49, max(q - 1, 0)], length=q)
    points = _unique_indices([0, 1, max(p - 1, 0)], length=p)
    channels = _unique_indices([0, 1, 2, 7, 15, 31], length=c)

    samples: list[dict[str, Any]] = []
    for ni in ns:
        for qi in queries:
            for pi in points:
                for ch in channels:
                    idx = [ni, qi, pi, ch]
                    samples.append({"index": idx, "value": _sample_scalar(x, idx)})
    return samples


def _inverse_sigmoid(x: "torch.Tensor", eps: float = 1e-5) -> "torch.Tensor":
    import torch

    x = x.clamp(min=0, max=1)
    x1 = x.clamp(min=eps)
    x2 = (1 - x).clamp(min=eps)
    return torch.log(x1 / x2)


def _mask_to_box_coordinate(mask: "torch.Tensor", *, dtype: "torch.dtype") -> "torch.Tensor":
    import torch

    mask = mask.bool()
    height, width = mask.shape[-2:]

    y_coords, x_coords = torch.meshgrid(
        torch.arange(height, device=mask.device),
        torch.arange(width, device=mask.device),
        indexing="ij",
    )
    x_coords = x_coords.to(dtype)
    y_coords = y_coords.to(dtype)

    sentinel = torch.tensor(torch.finfo(dtype).max, device=mask.device, dtype=dtype)

    x_coords_masked = x_coords * mask
    x_max = x_coords_masked.flatten(start_dim=-2).max(dim=-1).values + 1
    x_min = torch.where(mask, x_coords_masked, sentinel).flatten(start_dim=-2).min(dim=-1).values

    y_coords_masked = y_coords * mask
    y_max = y_coords_masked.flatten(start_dim=-2).max(dim=-1).values + 1
    y_min = torch.where(mask, y_coords_masked, sentinel).flatten(start_dim=-2).min(dim=-1).values

    unnormalized_bbox = torch.stack([x_min, y_min, x_max, y_max], dim=-1)

    is_mask_non_empty = torch.any(mask, dim=(-2, -1)).unsqueeze(-1)
    unnormalized_bbox = unnormalized_bbox * is_mask_non_empty

    norm_tensor = torch.tensor([width, height, width, height], device=mask.device, dtype=dtype)
    normalized_bbox_xyxy = unnormalized_bbox / norm_tensor

    x_min_norm, y_min_norm, x_max_norm, y_max_norm = normalized_bbox_xyxy.unbind(dim=-1)
    center_x = (x_min_norm + x_max_norm) / 2
    center_y = (y_min_norm + y_max_norm) / 2
    box_width = x_max_norm - x_min_norm
    box_height = y_max_norm - y_min_norm

    return torch.stack([center_x, center_y, box_width, box_height], dim=-1)


def main() -> None:
    args = _parse_args()
    if args.include_decoder_intermediates:
        args.include_intermediates = True

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

    enc_outputs_class = None

    def _capture_enc_outputs_class(_module, _inputs, output):  # type: ignore[no-untyped-def]
        nonlocal enc_outputs_class
        enc_outputs_class = output.detach()

    handle = model.model.enc_score_head.register_forward_hook(_capture_enc_outputs_class)
    with torch.no_grad():
        outputs = model(**inputs)
    handle.remove()

    if enc_outputs_class is None:
        raise SystemExit("Failed to capture encoder class logits for top-k indices.")

    max_scores = enc_outputs_class.max(-1).values
    _, topk_ind = torch.topk(max_scores, model.config.num_queries, dim=1)
    encoder_topk_indices: list[int] = [int(x) for x in topk_ind[0].detach().cpu().tolist()]

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

    # Keep the probe set small but representative. Avoid indices that are unstable on MPS/float16 across ports.
    query_indices = [0, 1, 2, 10, 49, 100, 200, max(0, num_queries - 1)]
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

    intermediates: dict[str, Any] | None = None
    if args.include_intermediates:
        from transformers.models.pp_doclayout_v3 import modeling_pp_doclayout_v3 as m

        model_core = model.model
        decoder_level_tensors: dict[str, tuple[str, torch.Tensor]] = {}
        pixel_mask = inputs.get("pixel_mask")
        if pixel_mask is None:
            # Match Transformers default: if pixel_mask is omitted, it is treated as fully-valid.
            if int(pixel_values.shape[1]) == 3:
                height = int(pixel_values.shape[2])
                width = int(pixel_values.shape[3])
            else:
                height = int(pixel_values.shape[1])
                width = int(pixel_values.shape[2])
            pixel_mask = torch.ones(
                (int(pixel_values.shape[0]), height, width),
                device=pixel_values.device,
                dtype=torch.bool,
            )

        with torch.no_grad():
            # Backbone returns list[(feature_map, mask)], where feature_map is NCHW.
            backbone_features = model_core.backbone(pixel_values, pixel_mask)
            x4_feat = backbone_features.pop(0)  # (feat, mask)

            # Encoder input projection (NCHW).
            proj_conv_outs: list[torch.Tensor] = []
            proj_feats: list[torch.Tensor] = []
            for level, (source, _mask) in enumerate(backbone_features):
                # encoder_input_proj is a Sequential(conv, bn)
                proj = model_core.encoder_input_proj[level]
                conv_out = proj[0](source)
                bn_out = proj[1](conv_out)
                proj_conv_outs.append(conv_out)
                proj_feats.append(bn_out)

            # Hybrid encoder (NCHW).
            # `PPDocLayoutV3HybridEncoder` mutates its `feats` list in-place (it reassigns
            # selected feature map levels, e.g. `encode_proj_layers=[2]`), so keep a
            # stable copy of the pre-encoder projection outputs for parity samples.
            encoder_outputs = model_core.encoder(list(proj_feats), x4_feat)

            # Decoder input projections (NCHW) + flatten to [B,S,C].
            sources = [
                model_core.decoder_input_proj[level](source)
                for level, source in enumerate(encoder_outputs.last_hidden_state)
            ]
            if model_core.config.num_feature_levels > len(sources):
                _len_sources = len(sources)
                sources.append(model_core.decoder_input_proj[_len_sources](encoder_outputs.last_hidden_state[-1]))
                for i in range(_len_sources + 1, model_core.config.num_feature_levels):
                    sources.append(model_core.decoder_input_proj[i](encoder_outputs.last_hidden_state[-1]))

            source_flatten = []
            spatial_shapes_list = []
            for source in sources:
                height, width = source.shape[-2:]
                spatial_shapes_list.append((int(height), int(width)))
                source_flatten.append(source.flatten(2).transpose(1, 2))
            source_flatten = torch.cat(source_flatten, 1)

            anchors, valid_mask = model_core.generate_anchors(
                tuple(spatial_shapes_list),
                device=source_flatten.device,
                dtype=source_flatten.dtype,
            )

            memory = valid_mask.to(source_flatten.dtype) * source_flatten
            output_memory = model_core.enc_output(memory)
            enc_outputs_class_full = model_core.enc_score_head(output_memory)
            enc_outputs_coord_logits = model_core.enc_bbox_head(output_memory) + anchors

            # Top-k + reference points (pre mask-enhanced refinement).
            _, topk_ind = torch.topk(enc_outputs_class_full.max(-1).values, model_core.config.num_queries, dim=1)
            reference_points_unact = enc_outputs_coord_logits.gather(
                dim=1, index=topk_ind.unsqueeze(-1).repeat(1, 1, enc_outputs_coord_logits.shape[-1])
            )

            if model_core.config.mask_enhanced:
                batch_ind = torch.arange(memory.shape[0], device=output_memory.device).unsqueeze(1)
                target = output_memory[batch_ind, topk_ind]
                out_query = model_core.decoder_norm(target)
                mask_query_embed = model_core.mask_query_head(out_query)

                mask_feat = encoder_outputs.mask_feat  # [B,P,H,W]
                _, _, mask_h, mask_w = mask_feat.shape
                enc_out_masks = torch.bmm(mask_query_embed, mask_feat.flatten(start_dim=2)).reshape(
                    mask_query_embed.shape[0], mask_query_embed.shape[1], mask_h, mask_w
                )
                reference_points = _mask_to_box_coordinate(enc_out_masks > 0, dtype=reference_points_unact.dtype)
                reference_points_unact = _inverse_sigmoid(reference_points)

            if args.include_decoder_intermediates:
                decoder = model_core.decoder
                decoder_layer0 = decoder.layers[0]
                self_ln_weight = decoder_layer0.self_attn_layer_norm.weight.detach()
                self_ln_bias = decoder_layer0.self_attn_layer_norm.bias.detach()
                cross_ln_weight = decoder_layer0.encoder_attn_layer_norm.weight.detach()
                cross_ln_bias = decoder_layer0.encoder_attn_layer_norm.bias.detach()

                batch_ind = torch.arange(memory.shape[0], device=output_memory.device).unsqueeze(1)
                target = output_memory[batch_ind, topk_ind]  # [B,Q,D]

                hidden_states = target
                hidden_states_in = hidden_states.detach()
                reference_points = reference_points_unact.sigmoid()
                reference_points_input = reference_points.unsqueeze(2)
                object_query_pos = decoder.query_pos_head(reference_points)

                residual = hidden_states
                self_out, _ = decoder_layer0.self_attn(
                    hidden_states=hidden_states,
                    attention_mask=None,
                    position_embeddings=object_query_pos,
                )
                self_sum = residual + self_out
                self_sum_mean = self_sum.mean(-1, keepdim=True)
                self_sum_var = self_sum.var(-1, unbiased=False, keepdim=True)
                hidden_states = decoder_layer0.self_attn_layer_norm(self_sum)

                hidden_states_pre_cross = hidden_states.detach()
                hidden_states_pre_cross_mean = hidden_states_pre_cross.mean(-1, keepdim=True)

                encoder_attn = decoder_layer0.encoder_attn
                hs_with_pos = hidden_states + object_query_pos

                value = encoder_attn.value_proj(source_flatten)
                value = value.view(
                    int(value.shape[0]),
                    int(value.shape[1]),
                    int(encoder_attn.n_heads),
                    int(encoder_attn.d_model // encoder_attn.n_heads),
                )

                sampling_offsets = encoder_attn.sampling_offsets(hs_with_pos).view(
                    int(hs_with_pos.shape[0]),
                    int(hs_with_pos.shape[1]),
                    int(encoder_attn.n_heads),
                    int(encoder_attn.n_levels),
                    int(encoder_attn.n_points),
                    2,
                )
                attention_weights = encoder_attn.attention_weights(hs_with_pos).view(
                    int(hs_with_pos.shape[0]),
                    int(hs_with_pos.shape[1]),
                    int(encoder_attn.n_heads),
                    int(encoder_attn.n_levels * encoder_attn.n_points),
                )
                attention_weights = torch.softmax(attention_weights, -1).view(
                    int(hs_with_pos.shape[0]),
                    int(hs_with_pos.shape[1]),
                    int(encoder_attn.n_heads),
                    int(encoder_attn.n_levels),
                    int(encoder_attn.n_points),
                )

                sampling_locations = (
                    reference_points_input[:, :, None, :, None, :2]
                    + sampling_offsets / encoder_attn.n_points * reference_points_input[:, :, None, :, None, 2:] * 0.5
                )

                spatial_shapes = torch.tensor(spatial_shapes_list, device=source_flatten.device, dtype=torch.long)
                start_idx = [0]
                for height, width in spatial_shapes_list[:-1]:
                    start_idx.append(start_idx[-1] + int(height) * int(width))
                level_start_index = torch.tensor(start_idx, device=source_flatten.device, dtype=torch.long)

                # Mirror MultiScaleDeformableAttention internals (canonicalize to NHWC for Swift parity).
                value_list = value.split([height * width for height, width in spatial_shapes_list], dim=1)
                sampling_grids = 2 * sampling_locations - 1

                for level_id, (height, width) in enumerate(spatial_shapes_list):
                    value_l_ = (
                        value_list[level_id]
                        .flatten(2)
                        .transpose(1, 2)
                        .reshape(int(value.shape[0]) * int(encoder_attn.n_heads), int(value.shape[3]), height, width)
                    )
                    grid_l_ = sampling_grids[:, :, :, level_id].transpose(1, 2).flatten(0, 1)
                    sampled_l_ = torch.nn.functional.grid_sample(
                        value_l_,
                        grid_l_,
                        mode="bilinear",
                        padding_mode="zeros",
                        align_corners=False,
                    )

                    decoder_level_tensors[f"decoder.layers.0.encoder_attn.value.level{level_id}"] = (
                        "NHWC",
                        _nchw_to_nhwc(value_l_),
                    )
                    decoder_level_tensors[f"decoder.layers.0.encoder_attn.grid.level{level_id}"] = ("NQP2", grid_l_)
                    decoder_level_tensors[f"decoder.layers.0.encoder_attn.sampled.level{level_id}"] = (
                        "NQPC",
                        sampled_l_.permute(0, 2, 3, 1).contiguous(),
                    )

                cross_out, _ = encoder_attn(
                    hidden_states=hidden_states_pre_cross,
                    encoder_hidden_states=source_flatten,
                    position_embeddings=object_query_pos,
                    reference_points=reference_points_input,
                    spatial_shapes=spatial_shapes,
                    spatial_shapes_list=spatial_shapes_list,
                    level_start_index=level_start_index,
                    attention_mask=None,
                )
                cross_out_mean = cross_out.mean(-1, keepdim=True)

                cross_sum = hidden_states_pre_cross + cross_out
                cross_sum_detached = cross_sum.detach()
                cross_sum_mean = cross_sum_detached.mean(-1, keepdim=True)
                cross_sum_var = cross_sum_detached.var(-1, unbiased=False, keepdim=True)
                hidden_states_post_cross = decoder_layer0.encoder_attn_layer_norm(cross_sum)
                hidden_states_out = decoder_layer0.final_layer_norm(hidden_states_post_cross + decoder_layer0.mlp(hidden_states_post_cross))

                predicted_corners = decoder.bbox_embed(hidden_states_out)
                reference_points_out = (predicted_corners + _inverse_sigmoid(reference_points)).sigmoid()
                logits0 = decoder.class_embed(model_core.decoder_norm(hidden_states_out))

        # Canonical layout for cross-impl parity: use NHWC samples for feature maps.
        tensor_map: dict[str, tuple[str, torch.Tensor]] = {}
        tensor_map["pixel_values"] = ("NHWC", _nchw_to_nhwc(pixel_values))

        # backbone feature maps (including x4)
        all_feats = [x4_feat] + list(backbone_features)
        for idx, (feat, _mask) in enumerate(all_feats):
            tensor_map[f"backbone.feature_maps.{idx}"] = ("NHWC", _nchw_to_nhwc(feat))

        for idx, feat in enumerate(proj_conv_outs):
            tensor_map[f"encoder_input_proj_conv.{idx}"] = ("NHWC", _nchw_to_nhwc(feat))

        for idx, feat in enumerate(proj_feats):
            tensor_map[f"encoder_input_proj.{idx}"] = ("NHWC", _nchw_to_nhwc(feat))

        for idx, feat in enumerate(encoder_outputs.last_hidden_state):
            tensor_map[f"hybrid_encoder.feature_maps.{idx}"] = ("NHWC", _nchw_to_nhwc(feat))

        tensor_map["hybrid_encoder.mask_feat"] = ("NHWC", _nchw_to_nhwc(encoder_outputs.mask_feat))
        tensor_map["source_flatten"] = ("BSC", source_flatten)
        tensor_map["anchors"] = ("BS4", anchors)
        tensor_map["valid_mask"] = ("BS1", valid_mask)
        tensor_map["memory"] = ("BSC", memory)
        tensor_map["output_memory"] = ("BSC", output_memory)
        tensor_map["enc_outputs_class"] = ("ENC_CLASS", enc_outputs_class_full)
        tensor_map["enc_outputs_coord_logits"] = ("BS4", enc_outputs_coord_logits)
        tensor_map["reference_points_unact"] = ("BS4", reference_points_unact)

        if args.include_decoder_intermediates:
            tensor_map.update(decoder_level_tensors)
            tensor_map["decoder.layers.0.reference_points.in"] = ("BS4", reference_points)
            tensor_map["decoder.layers.0.object_query_pos"] = ("BSC", object_query_pos)
            tensor_map["decoder.layers.0.hidden_states.in"] = ("BSC_WIDE", hidden_states_in)
            tensor_map["decoder.layers.0.self_attn.out"] = ("BSC_WIDE", self_out)
            tensor_map["decoder.layers.0.self_attn_layer_norm.input_mean"] = ("BS1", self_sum_mean)
            tensor_map["decoder.layers.0.self_attn_layer_norm.input_var"] = ("BS1", self_sum_var)
            tensor_map["decoder.layers.0.self_attn_layer_norm.weight"] = ("C", self_ln_weight)
            tensor_map["decoder.layers.0.self_attn_layer_norm.bias"] = ("C", self_ln_bias)
            tensor_map["decoder.layers.0.hidden_states.pre_cross"] = ("BSC_WIDE", hidden_states_pre_cross)
            tensor_map["decoder.layers.0.hidden_states.pre_cross_mean"] = ("BS1", hidden_states_pre_cross_mean)
            tensor_map["decoder.layers.0.encoder_attn.sampling_offsets"] = ("BQHLP2", sampling_offsets)
            tensor_map["decoder.layers.0.encoder_attn.attention_weights"] = ("BQHLP", attention_weights)
            tensor_map["decoder.layers.0.encoder_attn.sampling_locations"] = ("BQHLP2", sampling_locations)
            tensor_map["decoder.layers.0.encoder_attn.out"] = ("BSC_WIDE", cross_out)
            tensor_map["decoder.layers.0.encoder_attn.out_mean"] = ("BS1", cross_out_mean)
            tensor_map["decoder.layers.0.encoder_attn_layer_norm.input"] = ("BSC_WIDE", cross_sum_detached)
            tensor_map["decoder.layers.0.encoder_attn_layer_norm.input_mean"] = ("BS1", cross_sum_mean)
            tensor_map["decoder.layers.0.encoder_attn_layer_norm.input_var"] = ("BS1", cross_sum_var)
            tensor_map["decoder.layers.0.encoder_attn_layer_norm.weight"] = ("C", cross_ln_weight)
            tensor_map["decoder.layers.0.encoder_attn_layer_norm.bias"] = ("C", cross_ln_bias)
            tensor_map["decoder.layers.0.hidden_states.post_cross"] = ("BSC", hidden_states_post_cross)
            tensor_map["decoder.layers.0.hidden_states.out"] = ("BSC", hidden_states_out)
            tensor_map["decoder.layers.0.bbox.predicted_corners"] = ("BS4", predicted_corners)
            tensor_map["decoder.layers.0.reference_points.out"] = ("BS4", reference_points_out)
            tensor_map["decoder.layers.0.logits"] = ("ENC_CLASS", logits0)

        order = [
            "pixel_values",
            "backbone.feature_maps.0",
            "backbone.feature_maps.1",
            "backbone.feature_maps.2",
            "backbone.feature_maps.3",
            "encoder_input_proj_conv.0",
            "encoder_input_proj.0",
            "encoder_input_proj_conv.1",
            "encoder_input_proj.1",
            "encoder_input_proj_conv.2",
            "encoder_input_proj.2",
            "hybrid_encoder.feature_maps.0",
            "hybrid_encoder.feature_maps.1",
            "hybrid_encoder.feature_maps.2",
            "hybrid_encoder.mask_feat",
            "source_flatten",
            "anchors",
            "valid_mask",
            "memory",
            "output_memory",
            "enc_outputs_class",
            "enc_outputs_coord_logits",
            "reference_points_unact",
        ]

        if args.include_decoder_intermediates:
            order += [
                "decoder.layers.0.reference_points.in",
                "decoder.layers.0.object_query_pos",
                "decoder.layers.0.hidden_states.in",
                "decoder.layers.0.self_attn.out",
                "decoder.layers.0.self_attn_layer_norm.input_mean",
                "decoder.layers.0.self_attn_layer_norm.input_var",
                "decoder.layers.0.self_attn_layer_norm.weight",
                "decoder.layers.0.self_attn_layer_norm.bias",
                "decoder.layers.0.hidden_states.pre_cross",
                "decoder.layers.0.hidden_states.pre_cross_mean",
                "decoder.layers.0.encoder_attn.sampling_offsets",
                "decoder.layers.0.encoder_attn.attention_weights",
                "decoder.layers.0.encoder_attn.sampling_locations",
            ]
            for level_id in range(len(spatial_shapes_list)):
                order += [
                    f"decoder.layers.0.encoder_attn.value.level{level_id}",
                    f"decoder.layers.0.encoder_attn.grid.level{level_id}",
                    f"decoder.layers.0.encoder_attn.sampled.level{level_id}",
                ]
            order += [
                "decoder.layers.0.encoder_attn.out",
                "decoder.layers.0.encoder_attn.out_mean",
                "decoder.layers.0.encoder_attn_layer_norm.input",
                "decoder.layers.0.encoder_attn_layer_norm.input_mean",
                "decoder.layers.0.encoder_attn_layer_norm.input_var",
                "decoder.layers.0.encoder_attn_layer_norm.weight",
                "decoder.layers.0.encoder_attn_layer_norm.bias",
                "decoder.layers.0.hidden_states.post_cross",
                "decoder.layers.0.hidden_states.out",
                "decoder.layers.0.bbox.predicted_corners",
                "decoder.layers.0.reference_points.out",
                "decoder.layers.0.logits",
            ]

        tensors_out: dict[str, Any] = {}
        for name in order:
            if name not in tensor_map:
                continue
            layout, tensor = tensor_map[name]
            shape = [int(v) for v in tensor.shape]
            dtype_str = str(tensor.dtype).replace("torch.", "")

            if layout == "NHWC":
                samples = _sample_nhwc(tensor)
            elif layout == "BSC":
                samples = _sample_bsc(tensor)
            elif layout == "BSC_WIDE":
                samples = _sample_bsc_wide(tensor)
            elif layout == "C":
                samples = _sample_c(tensor)
            elif layout == "BS4":
                samples = _sample_bs4(tensor)
            elif layout == "BS1":
                samples = _sample_bs1(tensor)
            elif layout == "ENC_CLASS":
                samples = _sample_enc_outputs_class(tensor)
                layout = "BSC"
            elif layout == "BQHLP2":
                samples = _sample_decoder_offsets(tensor)
            elif layout == "BQHLP":
                samples = _sample_decoder_attention_weights(tensor)
            elif layout == "NQP2":
                samples = _sample_nqp2(tensor)
            elif layout == "NQPC":
                samples = _sample_nqpc(tensor)
            else:
                raise ValueError(f"Unknown layout: {layout}")

            tensors_out[name] = {
                "layout": layout,
                "shape": shape,
                "dtype": dtype_str,
                "stats": _stats_from_values([float(s["value"]) for s in samples]),
                "samples": samples,
            }

        intermediates = {"order": order, "tensors": tensors_out}

    fixture: dict[str, Any] = {
        "metadata": {
            "fixture_version": "v4" if args.include_decoder_intermediates else ("v3" if args.include_intermediates else "v2"),
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
        "encoder_topk_indices": encoder_topk_indices,
        "query_indices": query_indices,
        "class_indices": class_indices,
        "logits_slice": logits_slice,
        "pred_boxes_slice": boxes_slice,
    }
    if intermediates is not None:
        fixture["intermediates"] = intermediates

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(fixture, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")
    print(f"Wrote fixture: {out_path}")


if __name__ == "__main__":
    main()
