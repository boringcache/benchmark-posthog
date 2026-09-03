#!/usr/bin/env python3

import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ACTIVATE = ROOT / "scripts/activate-docker-plan.py"


class ActivateDockerPlanTest(unittest.TestCase):
    def activate(self, *args: str) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            plan = Path(directory) / ".boringcache.toml"
            plan.write_text((ROOT / ".boringcache.toml").read_text())
            subprocess.run(
                [sys.executable, str(ACTIVATE), "--plan", str(plan), *args],
                check=True,
            )
            return tomllib.loads(plan.read_text())

    def test_plain_case_keeps_a_direct_build_request(self) -> None:
        plan = self.activate(
            "--dockerfile", "upstream/Dockerfile",
            "--platform", "linux/amd64",
            "--tool-cache", "false",
            "--mount-cache", "false",
            "--no-cache", "false",
            "--sourcemap-secret", "false",
            "--push", "false",
            "--image", "ghcr.io/acme/posthog:boringcache",
        )
        docker = plan["adapters"]["docker"]
        self.assertEqual(docker["command"][:3], ["docker", "buildx", "build"])
        self.assertNotIn("tool-cache", docker)
        self.assertNotIn("mount-cache", docker)

    def test_tool_and_mount_cache_case_keeps_all_composition_in_the_plan(self) -> None:
        plan = self.activate(
            "--dockerfile", ".benchmark/PostHog.Dockerfile",
            "--platform", "linux/amd64",
            "--tool-cache", "true",
            "--mount-cache", "true",
            "--no-cache", "true",
            "--sourcemap-secret", "true",
            "--push", "true",
            "--image", "ghcr.io/acme/posthog:boringcache",
        )
        docker = plan["adapters"]["docker"]
        self.assertEqual(docker["tool-cache"], ["turbo"])
        self.assertIs(docker["mount-cache"], True)
        self.assertIn("--no-cache", docker["command"])
        self.assertIn("--secret", docker["command"])
        self.assertIn("--push", docker["command"])
        self.assertEqual(plan["adapters"]["turbo"]["tag"], "posthog-turbo-local")


if __name__ == "__main__":
    unittest.main()
