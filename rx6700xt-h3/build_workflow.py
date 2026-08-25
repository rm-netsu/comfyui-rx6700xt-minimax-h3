"""Create the RX 6700 XT starter workflow from Comfy-Org's H3 template."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

SUBGRAPH_ID = "79dd8a95-ce9d-4c14-b264-2162e8bec5ce"
DIFFUSION = "minimax_h3_fl2va_pruned-w4a8_convrot_pruned.safetensors"
TEXT_ENCODER = "qwen3vl_32b_minimax_h3-int4_convrot.safetensors"
PROMPT = (
    "Cinematic wildlife documentary at sunrise. A red fox walks slowly through a misty "
    "pine clearing, dew sparkling on the grass, natural fur motion, gentle handheld camera. "
    "Audio: quiet birds, light wind in the pines, soft footsteps on wet grass. "
    "No text, subtitles, logos or watermarks."
)


def tune_workflow(workflow: dict) -> dict:
    outer = next(node for node in workflow["nodes"] if node["type"] == SUBGRAPH_ID)
    values = outer["widgets_values"]
    values[0] = PROMPT
    values[1] = 608
    values[2] = 352
    values[3] = 2
    values[5] = DIFFUSION
    values[6] = TEXT_ENCODER
    values[9] = False

    named = outer["widgets_values_named"]
    named.update(
        {
            "prompt": PROMPT,
            "width": 608,
            "height": 352,
            "value_1": 2,
            "unet_name": DIFFUSION,
            "clip_name": TEXT_ENCODER,
            "value": False,
        }
    )

    selector = next(node for node in workflow["nodes"] if node["type"] == "ResolutionSelector")
    selector["widgets_values"][1] = 0.2

    subgraph = next(graph for graph in workflow["definitions"]["subgraphs"] if graph["id"] == SUBGRAPH_ID)
    by_id = {node["id"]: node for node in subgraph["nodes"]}
    by_id[127]["widgets_values"][0] = DIFFUSION
    by_id[128]["widgets_values"][0] = TEXT_ENCODER
    by_id[131]["widgets_values"][0] = PROMPT
    by_id[131]["widgets_values"][1:4] = [608, 352, 56]
    by_id[133]["widgets_values"][0] = 2
    by_id[137]["widgets_values"][0] = 15

    note = next(node for node in workflow["nodes"] if node.get("title") == "Note: Model Links")
    note["widgets_values"][0] = (
        "## RX 6700 XT / gfx1031 model set\n\n"
        "This workflow uses the W4A8 diffusion model and INT4 text encoder from "
        "Winnougan/MiniMax-H3-INT4_Convrot_ComfyUI. The two VAEs come from "
        "Comfy-Org/MiniMax-H3. Run `download-minimax-h3-models.bat -AcceptLicenses` "
        "to download the exact pinned revisions and verify SHA-256.\n\n"
        "The 608x352, 2-second, 15-step preset is the first-run validation target for a "
        "12 GiB RX 6700 XT. Increase duration first, then resolution. Turbo mode stays off "
        "unless its optional LoRA has been downloaded."
    )

    workflow.setdefault("extra", {})["rx6700xt_h3_profile"] = {
        "profile_version": 1,
        "target": "RX 6700 XT / gfx1031 / 12 GiB",
        "source_template_commit": "2ded761bde3af3b4c8e905e162f45551cbec12ea",
        "diffusion": DIFFUSION,
        "text_encoder": TEXT_ENCODER,
        "starter_resolution": [608, 352],
        "starter_duration_seconds": 2,
        "steps": 15,
        "turbo": False,
    }
    return workflow


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    workflow = json.loads(args.source.read_text(encoding="utf-8"))
    tuned = tune_workflow(workflow)
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    args.destination.write_text(json.dumps(tuned, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
