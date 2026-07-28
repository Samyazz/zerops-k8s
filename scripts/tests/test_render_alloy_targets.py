#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RENDER = ROOT / "observability" / "prometheus" / "render-alloy-targets.sh"


class RenderAlloyTargetsTests(unittest.TestCase):
    def run_render(self, targets):
        temp_root = Path(tempfile.mkdtemp())
        body = RENDER.read_text(encoding="utf-8")
        body = body.replace("/var/www/targets", str(temp_root))
        script = temp_root / "render.sh"
        script.write_text(body, encoding="utf-8")
        script.chmod(0o755)
        result = subprocess.run(
            ["sh", str(script)],
            env={**os.environ, "K8S_ALLOY_SCRAPE_TARGETS": targets},
            capture_output=True,
            text=True,
            check=False,
        )
        output = temp_root / "alloy.json"
        payload = None
        if result.returncode == 0 and output.exists():
            payload = json.loads(output.read_text(encoding="utf-8"))
        return result, payload

    def test_renders_file_sd_payload(self):
        result, payload = self.run_render(
            "k8sworker1.zerops:12345,k8sworker2.zerops:12345"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            payload,
            [{"targets": ["k8sworker1.zerops:12345", "k8sworker2.zerops:12345"], "labels": {}}],
        )

    def test_rejects_invalid_target(self):
        result, _payload = self.run_render("bad target:12345")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid Alloy scrape target", result.stderr)


if __name__ == "__main__":
    unittest.main()
