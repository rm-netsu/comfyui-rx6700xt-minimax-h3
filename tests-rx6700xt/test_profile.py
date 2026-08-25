from __future__ import annotations

import importlib.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE_DIR = ROOT / "rx6700xt-h3"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.profile = json.loads((PROFILE_DIR / "profile.json").read_text(encoding="utf-8"))
        cls.manifest = json.loads((PROFILE_DIR / "models.json").read_text(encoding="utf-8"))
        cls.downloader = load_module("download_models", PROFILE_DIR / "download_models.py")

    def test_target_is_native_gfx1031(self):
        self.assertEqual(self.profile["target"]["gfx"], "gfx1031")
        self.assertIn("DEV_73DF", self.profile["target"]["pci_device_id"])

    def test_every_model_is_revision_and_hash_pinned(self):
        destinations = set()
        for model in self.manifest["models"]:
            self.assertRegex(model["revision"], r"^[0-9a-f]{40}$")
            self.assertRegex(model["sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(model["size"], 0)
            self.assertNotIn("..", Path(model["destination"]).parts)
            self.assertNotIn(model["destination"], destinations)
            destinations.add(model["destination"])

    def test_default_download_selection(self):
        selected = self.downloader.selected_models(self.manifest, "fl2va", "int4", False)
        self.assertEqual(
            {model["id"] for model in selected},
            {"fl2va-w4a8", "text-int4", "video-vae", "audio-vae"},
        )

    def test_constraints_match_profile(self):
        constraints = (PROFILE_DIR / "constraints.txt").read_text(encoding="utf-8")
        self.assertIn(f"torch=={self.profile['rocm']['torch']}", constraints)
        self.assertIn("amd-torch-device-gfx1031==", constraints)
        self.assertIn(
            f"triton-windows=={self.profile['extensions']['triton_windows']}", constraints
        )

    def test_w4a8_optimization_is_packaged_and_installed(self):
        patch = PROFILE_DIR / "patches" / "comfyui-int8-fast-rocm-gfx1031.patch"
        patch_text = patch.read_text(encoding="utf-8")
        self.assertIn("GFX1031_W4A8_OPTIMIZED = True", patch_text)
        self.assertIn("_dequant_int4_grouped_to_int8", patch_text)
        installer = (PROFILE_DIR / "Install.ps1").read_text(encoding="utf-8")
        self.assertIn(patch.name, installer)
        launcher = (PROFILE_DIR / "Start-ComfyUI.ps1").read_text(encoding="utf-8")
        self.assertIn('$env:TRITON_CACHE_AUTOTUNING = "1"', launcher)

    def test_64gb_profile_uses_bounded_async_offload(self):
        launcher = (PROFILE_DIR / "Start-ComfyUI.ps1").read_text(encoding="utf-8")
        self.assertIn('[string]$Profile = "Performance64GB"', launcher)
        self.assertIn('"--async-offload", $AsyncOffloadStreams.ToString()', launcher)
        self.assertIn('"--pinned-memory-limit", $PinnedMemoryLimitGiB.ToString(', launcher)

        cli_args = (ROOT / "comfy" / "cli_args.py").read_text(encoding="utf-8")
        memory_management = (ROOT / "comfy" / "model_management.py").read_text(encoding="utf-8")
        self.assertIn('parser.add_argument("--pinned-memory-limit"', cli_args)
        self.assertIn("MAX_PINNED_MEMORY = min(MAX_PINNED_MEMORY", memory_management)

    def test_profile_user_facing_text_is_english(self):
        paths = [ROOT / "README.md", ROOT / "sample-workflows" / "MiniMax_H3_RX6700XT_W4A8_2s.json"]
        paths.extend(PROFILE_DIR.rglob("*.md"))
        paths.extend(PROFILE_DIR.rglob("*.ps1"))
        paths.extend(PROFILE_DIR.rglob("*.py"))
        paths.extend(ROOT.glob("*-rx6700xt-h3.bat"))
        paths.extend(ROOT.glob("start-minimax-h3-*.bat"))
        for path in paths:
            with self.subTest(path=path.relative_to(ROOT)):
                text = path.read_text(encoding="utf-8")
                self.assertIsNone(re.search(r"[А-Яа-яЁё]", text))

    def test_launcher_does_not_spoof_gpu_or_bypass_policy(self):
        scripts = "\n".join(path.read_text(encoding="utf-8") for path in PROFILE_DIR.glob("*.ps1"))
        self.assertNotIn("HSA_OVERRIDE_GFX_VERSION", scripts.replace("Do not add HSA_OVERRIDE_GFX_VERSION here.", ""))
        wrapper_names = (
            "install-rx6700xt-h3.bat",
            "download-minimax-h3-models.bat",
            "start-minimax-h3-local.bat",
            "start-minimax-h3-lan.bat",
            "diagnose-rx6700xt-h3.bat",
        )
        wrappers = "\n".join((ROOT / name).read_text(encoding="utf-8") for name in wrapper_names)
        self.assertNotRegex(wrappers, re.compile(r"ExecutionPolicy\s+Bypass", re.IGNORECASE))
        self.assertIn("ROCM_INT8_KITCHEN_PATCH = \"force\"", scripts)

    def test_detect_gpu_maps_rx6700xt_pci_id(self):
        detect_gpu = load_module("detect_gpu", ROOT / "detect_gpu.py")
        result = detect_gpu.match_gpu_to_gfx(
            {
                "name": "AMD Radeon RX 6700 XT",
                "pnp_id": "PCI\\VEN_1002&DEV_73DF&SUBSYS_00000000",
            }
        )
        self.assertEqual(result[0], "gfx1031")


if __name__ == "__main__":
    unittest.main()
