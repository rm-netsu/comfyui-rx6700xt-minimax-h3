"""Runtime diagnostics for the pinned RX 6700 XT MiniMax H3 profile."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
import subprocess
import sys
from pathlib import Path


EXPECTED = {
    "torch": "2.12.0+rocm7.15.0a20260728",
    "torchvision": "0.27.0+rocm7.15.0a20260728",
    "torchaudio": "2.11.0+rocm7.15.0a20260728",
    "amd-torch-device-gfx1031": "2.12.0+rocm7.15.0a20260728",
    "rocm-sdk-devel": "7.15.0a20260728",
    "triton-windows": "3.7.0.post26",
    "comfy-kitchen": "0.2.31",
    "comfy-aimdo": "0.4.13",
}
PATCH_COMMIT = "78e9875550df441c17ed2a225deae90c4211a09f"


def package_versions() -> tuple[dict[str, str | None], list[str]]:
    versions: dict[str, str | None] = {}
    errors: list[str] = []
    for name, expected in EXPECTED.items():
        try:
            actual = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            actual = None
        versions[name] = actual
        if actual != expected:
            errors.append(f"{name}: expected {expected}, got {actual}")
    return versions, errors


def git_commit(path: Path) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
        return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--require-models", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()

    report: dict = {"ok": False, "errors": [], "warnings": []}
    versions, version_errors = package_versions()
    report["packages"] = versions
    report["errors"].extend(version_errors)

    try:
        import torch

        report["torch"] = {
            "version": torch.__version__,
            "hip": torch.version.hip,
            "cuda_api_available": torch.cuda.is_available(),
        }
        if not torch.cuda.is_available():
            report["errors"].append("torch.cuda.is_available() is False")
        else:
            device = torch.cuda.get_device_properties(0)
            arch_list = list(torch.cuda.get_arch_list())
            report["gpu"] = {
                "name": torch.cuda.get_device_name(0),
                "arch_list": arch_list,
                "vram_gib": round(device.total_memory / 2**30, 2),
            }
            if not any(arch.startswith("gfx1031") for arch in arch_list):
                report["errors"].append(f"gfx1031 is missing from torch arch list: {arch_list}")
            if "6700" not in torch.cuda.get_device_name(0) and "6750" not in torch.cuda.get_device_name(0):
                report["warnings"].append("GPU name is not RX 6700/6750; verify that the selected device is gfx1031")

            left = torch.randn((256, 256), device="cuda", dtype=torch.float16)
            right = torch.randn((256, 256), device="cuda", dtype=torch.float16)
            result = left @ right
            torch.cuda.synchronize()
            if not torch.isfinite(result).all().item():
                report["errors"].append("FP16 ROCm matrix multiplication produced non-finite values")
            report["fp16_matmul"] = "ok"
    except Exception as exc:  # diagnostics must preserve the error in the report
        report["errors"].append(f"PyTorch/ROCm test failed: {type(exc).__name__}: {exc}")

    node = root / "custom_nodes" / "ComfyUI-INT8-Fast-ROCM"
    actual_patch_commit = git_commit(node)
    report["int8_patch_commit"] = actual_patch_commit
    if actual_patch_commit != PATCH_COMMIT:
        report["errors"].append(f"INT8 patch: expected {PATCH_COMMIT}, got {actual_patch_commit}")

    optimized_kernel = node / "int8_fused_kernel.py"
    optimized_bridge = node / "rocm_int8_kitchen_patch.py"
    optimization_ok = (
        optimized_kernel.exists()
        and "GFX1031_W4A8_OPTIMIZED = True" in optimized_kernel.read_text(encoding="utf-8")
        and optimized_bridge.exists()
        and "ck_w4a8_eager._dequant_int4_grouped_to_int8 = ck_w4a8_triton._dequant_int4_grouped_to_int8"
        in optimized_bridge.read_text(encoding="utf-8")
    )
    report["w4a8_gfx1031_optimization"] = "ok" if optimization_ok else "missing"
    if not optimization_ok:
        report["errors"].append("The packaged gfx1031 W4A8 fused-decode optimization is missing")

    manifest = json.loads((root / "rx6700xt-h3" / "models.json").read_text(encoding="utf-8"))
    default_models = [model for model in manifest["models"] if model.get("default")]
    model_state = {}
    for model in default_models:
        path = root / model["destination"]
        present = path.exists() and path.stat().st_size == int(model["size"])
        model_state[model["id"]] = {"present": present, "path": str(path)}
        if not present and args.require_models:
            report["errors"].append(f"Missing model: {path}")
    report["models"] = model_state

    if args.full and not report["errors"]:
        smoke_test = node / "test_rocm_int8_patch.py"
        process = subprocess.run(
            [sys.executable, str(smoke_test)],
            cwd=str(node),
            env={**os.environ, "ROCM_INT8_KITCHEN_PATCH": "force"},
            text=True,
            capture_output=True,
            timeout=300,
        )
        report["int8_smoke_test"] = {
            "exit_code": process.returncode,
            "stdout": process.stdout[-8000:],
            "stderr": process.stderr[-8000:],
        }
        if process.returncode != 0:
            report["errors"].append("RDNA2 INT8/W4A8 Triton smoke test failed")

    report["ok"] = not report["errors"]
    args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    print("MiniMax H3 / RX 6700 XT diagnostic")
    print(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"Report: {args.report}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
