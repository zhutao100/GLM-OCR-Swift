#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import io
import json
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, TypedDict, cast


try:
    import numpy as np
    from PIL import Image, ImageEnhance, ImageOps
except ModuleNotFoundError as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependencies. Run with the repo's Python env, e.g.\n"
        "  PYENV_VERSION=venv313 pyenv exec python3 scripts/gateway_preprocessing_generate_degraded_lane.py\n"
        f"Original error: {exc}"
    ) from exc


class ManifestBase(TypedDict):
    name: str
    source_path: str


class BorderDarkMarginFamily(TypedDict):
    border_fraction: float
    border_rgb: list[int]
    inner_padding_fraction: float


class SkewSmallAngleFamily(TypedDict):
    degrees: float
    fill_rgb: list[int]
    resample: Literal["bicubic"]


class PerspectiveWarpFamily(TypedDict):
    corner_offsets_fraction: dict[str, list[float]]
    fill_rgb: list[int]
    resample: Literal["bicubic"]


class LowContrastShadowGradient(TypedDict):
    direction: Literal["left_to_right"]
    strength: float


class LowContrastShadowFamily(TypedDict):
    contrast_factor: float
    brightness_factor: float
    shadow_gradient: LowContrastShadowGradient


class NoiseAndJPEGFamily(TypedDict):
    gaussian_sigma: float
    jpeg_quality: int


FamilyParams = (
    BorderDarkMarginFamily | SkewSmallAngleFamily | PerspectiveWarpFamily | LowContrastShadowFamily | NoiseAndJPEGFamily
)


class ManifestVariant(TypedDict):
    name: str
    base: str
    family: str


class Manifest(TypedDict):
    version: int
    notes: str
    seed: int
    bases: list[ManifestBase]
    families: dict[str, FamilyParams]
    variants: list[ManifestVariant]


@dataclass(frozen=True)
class VariantIndexEntry:
    name: str
    base: str
    family: str
    source_png: str
    sha256_png: str


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _resolve_repo_root(explicit: str | None) -> Path:
    if explicit is None:
        return Path.cwd().resolve()
    return Path(explicit).expanduser().resolve()


def _resolve_manifest_path(repo_root: Path, explicit: str | None) -> Path:
    if explicit is None:
        return repo_root / "docs" / "dev_plans" / "quality_parity" / "gateway_preprocessing" / "degraded_lane_manifest.json"
    p = Path(explicit).expanduser()
    return p if p.is_absolute() else (repo_root / p)


def _resolve_out_root(repo_root: Path, explicit: str | None) -> Path:
    if explicit is None:
        return repo_root / ".build" / "gateway_preprocessing" / "degraded_lane_repo"
    p = Path(explicit).expanduser()
    return p if p.is_absolute() else (repo_root / p)


def _copy_expected_baseline(
    *,
    repo_root: Path,
    out_root: Path,
    variant_name: str,
    base_name: str,
) -> None:
    def copy_dir(src_dir: Path, dst_dir: Path) -> None:
        dst_dir.mkdir(parents=True, exist_ok=True)
        for suffix in [".md", ".json"]:
            src_file = src_dir / f"{base_name}{suffix}"
            if not src_file.is_file():
                continue
            shutil.copy2(src_file, dst_dir / f"{variant_name}{suffix}")

    copy_dir(
        repo_root / "examples" / "reference_result" / base_name,
        out_root / "examples" / "reference_result" / variant_name,
    )
    copy_dir(
        repo_root / "examples" / "golden_result" / base_name,
        out_root / "examples" / "golden_result" / variant_name,
    )


def _resample(name: str) -> int:
    if name == "bicubic":
        return Image.Resampling.BICUBIC
    raise ValueError(f"Unsupported resample: {name}")


def _apply_border_dark_margin(img: Image.Image, params: BorderDarkMarginFamily) -> Image.Image:
    w, h = img.size
    border_x = max(int(round(float(params["border_fraction"]) * float(w))), 1)
    border_y = max(int(round(float(params["border_fraction"]) * float(h))), 1)
    inner_pad = int(round(float(params["inner_padding_fraction"]) * float(min(w, h))))

    border_rgb = tuple(int(c) for c in params["border_rgb"])
    if len(border_rgb) != 3:
        raise ValueError("border_rgb must have length 3")

    padded = ImageOps.expand(img, border=max(inner_pad, 0), fill=(255, 255, 255)) if inner_pad > 0 else img
    canvas = Image.new("RGB", (padded.width + 2 * border_x, padded.height + 2 * border_y), border_rgb)
    canvas.paste(padded, (border_x, border_y))
    return canvas


def _apply_skew_small_angle(img: Image.Image, params: SkewSmallAngleFamily) -> Image.Image:
    fill_rgb = tuple(int(c) for c in params["fill_rgb"])
    if len(fill_rgb) != 3:
        raise ValueError("fill_rgb must have length 3")
    return img.rotate(
        float(params["degrees"]),
        resample=_resample(params["resample"]),
        expand=False,
        fillcolor=fill_rgb,
    )


def _perspective_coeffs(dst_points: list[tuple[float, float]], src_points: list[tuple[float, float]]) -> list[float]:
    if len(dst_points) != 4 or len(src_points) != 4:
        raise ValueError("Expected 4 dst and 4 src points")

    a = np.zeros((8, 8), dtype=np.float64)
    b = np.zeros((8,), dtype=np.float64)
    for i, ((x_dst, y_dst), (x_src, y_src)) in enumerate(zip(dst_points, src_points, strict=True)):
        row = i * 2
        a[row, 0:3] = [x_dst, y_dst, 1.0]
        a[row, 6:8] = [-x_src * x_dst, -x_src * y_dst]
        b[row] = x_src

        a[row + 1, 3:6] = [x_dst, y_dst, 1.0]
        a[row + 1, 6:8] = [-y_src * x_dst, -y_src * y_dst]
        b[row + 1] = y_src

    coeffs = np.linalg.solve(a, b)
    return [float(v) for v in coeffs]


def _apply_perspective_warp(img: Image.Image, params: PerspectiveWarpFamily) -> Image.Image:
    w, h = img.size
    w1 = float(w - 1)
    h1 = float(h - 1)

    offsets = params["corner_offsets_fraction"]
    required = {"top_left", "top_right", "bottom_right", "bottom_left"}
    if set(offsets.keys()) != required:
        missing = ", ".join(sorted(required - set(offsets.keys())))
        extra = ", ".join(sorted(set(offsets.keys()) - required))
        raise ValueError(f"corner_offsets_fraction keys must be {sorted(required)} (missing={missing}, extra={extra})")

    def dst(x: float, y: float, off_key: str) -> tuple[float, float]:
        dx, dy = offsets[off_key]
        return (x + float(dx) * w1, y + float(dy) * h1)

    dst_points = [
        dst(0.0, 0.0, "top_left"),
        dst(w1, 0.0, "top_right"),
        dst(w1, h1, "bottom_right"),
        dst(0.0, h1, "bottom_left"),
    ]
    src_points = [(0.0, 0.0), (w1, 0.0), (w1, h1), (0.0, h1)]

    coeffs = _perspective_coeffs(dst_points=dst_points, src_points=src_points)
    fill_rgb = tuple(int(c) for c in params["fill_rgb"])
    if len(fill_rgb) != 3:
        raise ValueError("fill_rgb must have length 3")

    return img.transform(
        (w, h),
        Image.Transform.PERSPECTIVE,
        coeffs,
        resample=_resample(params["resample"]),
        fillcolor=fill_rgb,
    )


def _apply_low_contrast_shadow(img: Image.Image, params: LowContrastShadowFamily) -> Image.Image:
    img = ImageEnhance.Contrast(img).enhance(float(params["contrast_factor"]))
    img = ImageEnhance.Brightness(img).enhance(float(params["brightness_factor"]))

    gradient = params["shadow_gradient"]
    direction = gradient["direction"]
    strength = float(gradient["strength"])
    if not (0.0 <= strength <= 1.0):
        raise ValueError("shadow_gradient.strength must be within [0, 1]")
    if direction != "left_to_right":
        raise ValueError(f"Unsupported shadow direction: {direction}")

    arr = np.asarray(img).astype(np.float32) / 255.0
    h, w, _ = arr.shape
    ramp = np.linspace(1.0 - strength, 1.0, w, dtype=np.float32)[None, :, None]
    shaded = np.clip(arr * ramp, 0.0, 1.0)
    out = (shaded * 255.0 + 0.5).astype(np.uint8)
    return Image.fromarray(out)


def _apply_noise_and_jpeg(img: Image.Image, params: NoiseAndJPEGFamily, *, rng: np.random.Generator) -> Image.Image:
    sigma = float(params["gaussian_sigma"])
    if sigma <= 0.0:
        raise ValueError("gaussian_sigma must be > 0")
    quality = int(params["jpeg_quality"])
    if not (1 <= quality <= 95):
        raise ValueError("jpeg_quality must be within [1, 95]")

    arr = np.asarray(img).astype(np.float32) / 255.0
    noise = rng.normal(0.0, sigma, size=arr.shape).astype(np.float32)
    noisy = np.clip(arr + noise, 0.0, 1.0)
    noisy_u8 = (noisy * 255.0 + 0.5).astype(np.uint8)
    noisy_img = Image.fromarray(noisy_u8)

    buf = io.BytesIO()
    noisy_img.save(
        buf,
        format="JPEG",
        quality=quality,
        subsampling=2,
        optimize=False,
        progressive=False,
    )
    buf.seek(0)
    reloaded = Image.open(buf)
    return reloaded.convert("RGB")


def _apply_family(
    img: Image.Image,
    family: str,
    params: FamilyParams,
    *,
    rng: np.random.Generator,
) -> Image.Image:
    if family == "border_dark_margin":
        return _apply_border_dark_margin(img, cast(BorderDarkMarginFamily, params))
    if family == "skew_small_angle":
        return _apply_skew_small_angle(img, cast(SkewSmallAngleFamily, params))
    if family == "perspective_warp":
        return _apply_perspective_warp(img, cast(PerspectiveWarpFamily, params))
    if family == "low_contrast_shadow":
        return _apply_low_contrast_shadow(img, cast(LowContrastShadowFamily, params))
    if family == "noise_and_jpeg":
        return _apply_noise_and_jpeg(img, cast(NoiseAndJPEGFamily, params), rng=rng)
    raise ValueError(f"Unknown family: {family}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Generate a synthetic degraded-input lane repo for gateway experiments.")
    parser.add_argument("--repo-root", help="Main repo root (default: CWD).")
    parser.add_argument("--manifest-path", help="Lane manifest (default: docs/.../degraded_lane_manifest.json).")
    parser.add_argument("--out-root", help="Output root (default: .build/gateway_preprocessing/degraded_lane_repo).")
    parser.add_argument("--clean", action="store_true", help="Remove the output root before generating.")
    args = parser.parse_args(argv)

    repo_root = _resolve_repo_root(args.repo_root)
    manifest_path = _resolve_manifest_path(repo_root, args.manifest_path)
    out_root = _resolve_out_root(repo_root, args.out_root)

    if args.clean and out_root.exists():
        shutil.rmtree(out_root)

    if not manifest_path.is_file():
        raise SystemExit(f"Missing manifest: {manifest_path}")

    manifest = cast(Manifest, _read_json(manifest_path))
    if int(manifest.get("version", 0)) != 1:
        raise SystemExit(f"Unsupported manifest version: {manifest.get('version')}")

    bases_by_name = {base["name"]: base for base in manifest["bases"]}
    families = manifest["families"]
    seed = int(manifest["seed"])

    source_dir = out_root / "examples" / "source"
    source_dir.mkdir(parents=True, exist_ok=True)

    entries: list[VariantIndexEntry] = []

    for variant in manifest["variants"]:
        name = variant["name"]
        base_name = variant["base"]
        family = variant["family"]

        if base_name not in bases_by_name:
            raise SystemExit(f"Unknown base for variant {name}: {base_name}")
        if family not in families:
            raise SystemExit(f"Unknown family for variant {name}: {family}")

        base = bases_by_name[base_name]
        base_path = repo_root / base["source_path"]
        if not base_path.is_file():
            raise SystemExit(f"Missing base source for {base_name}: {base_path}")

        name_hash = int.from_bytes(hashlib.sha256(name.encode("utf-8")).digest()[:8], "big", signed=False)
        rng = np.random.default_rng(seed + (name_hash % 1_000_000_000))
        with Image.open(base_path) as base_img:
            img = base_img.convert("RGB")
        degraded = _apply_family(img, family, families[family], rng=rng)

        out_png = source_dir / f"{name}.png"
        degraded.save(out_png, format="PNG", optimize=False)

        _copy_expected_baseline(repo_root=repo_root, out_root=out_root, variant_name=name, base_name=base_name)

        entries.append(
            VariantIndexEntry(
                name=name,
                base=base_name,
                family=family,
                source_png=str(out_png.relative_to(out_root)),
                sha256_png=_sha256(out_png),
            )
        )

    index = {
        "manifest_path": str(manifest_path.relative_to(repo_root)),
        "out_root": str(out_root),
        "seed": seed,
        "variants": [entry.__dict__ for entry in entries],
    }
    _write_json(out_root / "degraded_lane_index.json", index)

    print(f"Wrote lane repo: {out_root}")
    print(f"- source: {source_dir}")
    print(f"- index : {out_root / 'degraded_lane_index.json'}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv[1:]))
