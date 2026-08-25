from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / "sample-workflows" / "MiniMax_H3_RX6700XT_W4A8_2s.json"
SUBGRAPH_ID = "79dd8a95-ce9d-4c14-b264-2162e8bec5ce"


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = json.loads(WORKFLOW.read_text(encoding="utf-8"))

    def test_profile_metadata(self):
        profile = self.workflow["extra"]["rx6700xt_h3_profile"]
        self.assertEqual(profile["starter_resolution"], [608, 352])
        self.assertEqual(profile["starter_duration_seconds"], 2)
        self.assertEqual(profile["steps"], 15)
        self.assertFalse(profile["turbo"])

    def test_outer_node_uses_pinned_quantized_models(self):
        outer = next(node for node in self.workflow["nodes"] if node["type"] == SUBGRAPH_ID)
        named = outer["widgets_values_named"]
        self.assertEqual(named["width"], 608)
        self.assertEqual(named["height"], 352)
        self.assertIn("w4a8", named["unet_name"].lower())
        self.assertIn("int4", named["clip_name"].lower())
        self.assertFalse(named["value"])

    def test_workflow_uses_only_core_node_types(self):
        forbidden = {"OTUNetLoaderW8A8", "PathchSageAttentionKJ", "SpectrumApplyMiniMaxH3"}
        node_types = {node["type"] for node in self.workflow["nodes"]}
        for subgraph in self.workflow["definitions"]["subgraphs"]:
            node_types.update(node["type"] for node in subgraph["nodes"])
        self.assertTrue(node_types.isdisjoint(forbidden))


if __name__ == "__main__":
    unittest.main()
