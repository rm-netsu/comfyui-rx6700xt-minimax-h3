"""Explicit, resumable and hash-verified MiniMax H3 model downloader."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CHUNK_SIZE = 8 * 1024 * 1024
USER_AGENT = "minimax-h3-rx6700xt/1.0"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK_SIZE):
            digest.update(chunk)
    return digest.hexdigest()


def selected_models(manifest: dict, variant: str, text_encoder: str, include_turbo: bool) -> list[dict]:
    selected: list[dict] = []
    variants = {"fl2va", "ref2va"} if variant == "both" else {variant}
    for model in manifest["models"]:
        role = model["role"]
        if role == "diffusion" and model["variant"] in variants:
            selected.append(model)
        elif role == "text_encoder" and model.get("text_profile") == text_encoder:
            selected.append(model)
        elif role == "vae" and model["variant"] == "shared":
            selected.append(model)
        elif role == "lora" and include_turbo and model["variant"] in variants:
            selected.append(model)
    return selected


def model_url(model: dict) -> str:
    path = urllib.parse.quote(model["path"], safe="/")
    return f"https://huggingface.co/{model['repo']}/resolve/{model['revision']}/{path}"


def print_progress(name: str, completed: int, total: int, started: float) -> None:
    elapsed = max(time.monotonic() - started, 0.001)
    rate = completed / elapsed
    percent = completed * 100.0 / total if total else 0.0
    print(
        f"\r{name}: {percent:6.2f}%  {completed / 2**30:6.2f}/{total / 2**30:6.2f} GiB  "
        f"{rate / 2**20:5.1f} MiB/s",
        end="",
        flush=True,
    )


def download_once(model: dict, destination: Path) -> None:
    expected_size = int(model["size"])
    partial = destination.with_name(destination.name + ".part")
    destination.parent.mkdir(parents=True, exist_ok=True)

    if partial.exists() and partial.stat().st_size > expected_size:
        partial.unlink()
    offset = partial.stat().st_size if partial.exists() else 0
    if offset == expected_size:
        return

    request = urllib.request.Request(model_url(model), headers={"User-Agent": USER_AGENT})
    if offset:
        request.add_header("Range", f"bytes={offset}-")

    with urllib.request.urlopen(request, timeout=120) as response:
        status = getattr(response, "status", response.getcode())
        append = offset > 0 and status == 206
        if offset and not append:
            offset = 0
        mode = "ab" if append else "wb"
        completed = offset
        started = time.monotonic()
        last_update = 0.0
        with partial.open(mode) as output:
            while True:
                chunk = response.read(CHUNK_SIZE)
                if not chunk:
                    break
                output.write(chunk)
                completed += len(chunk)
                now = time.monotonic()
                if now - last_update >= 1.0:
                    print_progress(destination.name, completed, expected_size, started)
                    last_update = now
        print_progress(destination.name, completed, expected_size, started)
        print()


def ensure_model(model: dict, root: Path) -> None:
    destination = (root / model["destination"]).resolve()
    if root not in destination.parents:
        raise ValueError(f"Unsafe destination in manifest: {model['destination']}")
    expected_size = int(model["size"])
    expected_hash = model["sha256"].lower()

    if destination.exists() and destination.stat().st_size == expected_size:
        print(f"Verifying existing {destination.name} ...")
        if sha256_file(destination) == expected_hash:
            print(f"OK: {destination}")
            return
        raise RuntimeError(f"Existing file has the wrong SHA-256: {destination}")

    error: Exception | None = None
    for attempt in range(1, 4):
        try:
            print(f"Downloading {model['id']} (attempt {attempt}/3) ...")
            download_once(model, destination)
            partial = destination.with_name(destination.name + ".part")
            if not partial.exists() or partial.stat().st_size != expected_size:
                actual = partial.stat().st_size if partial.exists() else 0
                raise RuntimeError(f"Size mismatch: expected {expected_size}, got {actual}")
            print(f"Checking SHA-256 for {partial.name} ...")
            actual_hash = sha256_file(partial)
            if actual_hash != expected_hash:
                partial.unlink()
                raise RuntimeError(f"SHA-256 mismatch: expected {expected_hash}, got {actual_hash}")
            os.replace(partial, destination)
            print(f"OK: {destination}")
            return
        except (OSError, RuntimeError, urllib.error.URLError) as exc:
            error = exc
            print(f"Warning: {exc}", file=sys.stderr)
            if attempt < 3:
                time.sleep(attempt * 2)
    raise RuntimeError(f"Could not download {model['id']}: {error}")


def available_bytes(path: Path) -> int:
    return shutil.disk_usage(path).free


def remaining_bytes(models: list[dict], root: Path) -> int:
    total = 0
    for model in models:
        destination = root / model["destination"]
        if not destination.exists() or destination.stat().st_size != int(model["size"]):
            total += int(model["size"])
    return total


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--variant", choices=("fl2va", "ref2va", "both"), default="fl2va")
    parser.add_argument("--text-encoder", choices=("int4", "w4a8"), default="int4")
    parser.add_argument("--include-turbo", action="store_true")
    parser.add_argument("--accept-licenses", action="store_true")
    args = parser.parse_args()

    if not args.accept_licenses:
        parser.error("--accept-licenses is required")

    root = args.root.resolve()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    models = selected_models(manifest, args.variant, args.text_encoder, args.include_turbo)
    selected_size = sum(int(model["size"]) for model in models)
    required = remaining_bytes(models, root)
    reserve = 5 * 2**30
    print(
        f"Selected {len(models)} files, {selected_size / 2**30:.2f} GiB total; "
        f"up to {required / 2**30:.2f} GiB remains to download."
    )
    if available_bytes(root) < required + reserve:
        raise RuntimeError(
            f"Not enough free space. Need at least {(required + reserve) / 2**30:.1f} GiB "
            "including a 5 GiB safety margin."
        )

    for model in models:
        ensure_model(model, root)
    print("All selected MiniMax H3 files are present and verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
