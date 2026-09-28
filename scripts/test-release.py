#!/usr/bin/env python3
import copy
import contextlib
import io
import json
import pathlib
import runpy
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
release = runpy.run_path(str(ROOT / "scripts/release.py"))
metadata = runpy.run_path(str(ROOT / "scripts/release-config.py"))


class ReleaseGates(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((ROOT / "config/Release.json").read_text())
        self.revision = "a" * 40
        self.evidence = {key: True for key in release["GATES"]}
        self.evidence["sourceRevision"] = self.revision

    def errors(self, evidence=None, repository=None, dirty=False):
        return release["gate_errors"](self.config, self.evidence if evidence is None else evidence, self.revision,
                                      self.config["repository"] if repository is None else repository, dirty)

    def test_complete_evidence(self):
        self.assertEqual(self.errors(), [])

    def test_every_gate_requires_a_boolean_attestation(self):
        for gate in release["GATES"]:
            for invalid in [False, "true", 1, None]:
                evidence = copy.deepcopy(self.evidence)
                evidence[gate] = invalid
                self.assertTrue(self.errors(evidence), (gate, invalid))

    def test_source_identity_is_exact(self):
        self.assertTrue(self.errors(repository="other/tokenotch"))
        self.assertTrue(self.errors(repository=""))
        self.assertTrue(self.errors(evidence={}))
        self.assertTrue(self.errors(dirty=True))
        self.evidence["sourceRevision"] = "b" * 40
        self.assertTrue(self.errors())

    def test_unrecorded_acceptance_blocks_release(self):
        evidence = json.loads((ROOT / "config/ReleaseAcceptance.json").read_text())
        self.assertTrue(self.errors(evidence))

    def test_acceptance_template_matches_current_gates(self):
        evidence = json.loads((ROOT / "config/ReleaseAcceptance.json").read_text())
        self.assertEqual(set(evidence), {"sourceRevision", *release["GATES"]})
        self.assertEqual(evidence["sourceRevision"], "")
        self.assertTrue(all(evidence[gate] is False for gate in release["GATES"]))

    def test_notes_follow_release_version_and_must_not_be_empty(self):
        with tempfile.TemporaryDirectory(prefix="tokenotch-notes-test-") as temporary:
            root = pathlib.Path(temporary)
            notes = root / "docs/releases/1.1.0.md"
            notes.parent.mkdir(parents=True)
            config = {**self.config, "version": "1.1.0"}
            with patch.dict(release["release_notes"].__globals__, ROOT=root):
                with self.assertRaises(ValueError):
                    release["release_notes"](config)
                notes.write_text(" \n")
                with self.assertRaises(ValueError):
                    release["release_notes"](config)
                notes.write_text("# Tokenotch 1.1.0\n\nChanges for this version.\n")
                self.assertEqual(release["release_notes"](config), notes)

    def test_preflight_requires_the_matching_tag_without_building(self):
        with tempfile.TemporaryDirectory(prefix="tokenotch-preflight-test-") as temporary:
            evidence = pathlib.Path(temporary) / "acceptance.json"
            evidence.write_text(json.dumps(self.evidence))
            environment = {
                "TOKENOTCH_SIGNING_IDENTITY": "a" * 40,
                "TOKENOTCH_INSTALLER_IDENTITY": "b" * 40,
                "TOKENOTCH_TEAM_ID": "ABCDE12345",
                "TOKENOTCH_NOTARY_PROFILE": "test-only",
            }
            for tag in ["v" + self.config["version"], "v0.0.0"]:
                def run(*args, capture=False):
                    if args == ("git", "rev-parse", "HEAD"):
                        return self.revision
                    if args == ("git", "status", "--porcelain"):
                        return ""
                    if args == ("git", "describe", "--tags", "--exact-match"):
                        return tag
                    self.assertEqual(args[0], "python3", "Preflight must not build or sign")
                    return None
                with patch.dict(release["main"].__globals__, run=run,
                                repository_name=lambda: self.config["repository"]), \
                     patch.dict("os.environ", environment), \
                     patch("sys.argv", ["release.py", "--check", "--evidence", str(evidence)]), \
                     contextlib.redirect_stdout(io.StringIO()):
                    if tag == "v" + self.config["version"]:
                        release["main"]()
                    else:
                        with self.assertRaisesRegex(ValueError, "tag must exactly match"):
                            release["main"]()


class ReleaseMetadata(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenotch-metadata-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        for relative in ["config/Release.json", "config/Release.xcconfig",
                         "sources/Core/TokenotchProduct.swift", "integrations/VSCode/src/product.cjs",
                         "integrations/VSCode/package.json", "integrations/VSCode/package-lock.json",
                         "LICENSE", "integrations/VSCode/LICENSE", "scripts/release-config.py"]:
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)

    def run_metadata(self, *args):
        return subprocess.run(["python3", str(self.root / "scripts/release-config.py"), *args],
                              check=False, capture_output=True, text=True)

    def test_current_metadata_is_consistent(self):
        result = self.run_metadata()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_inconsistent_identity_is_rejected(self):
        path = self.root / "config/Release.json"
        config = json.loads(path.read_text())
        for key, value in [("repository", "other/tokenotch"), ("bundleID", "local.tokenotch.development"),
                           ("publisher", "someone-else")]:
            with self.subTest(key=key):
                path.write_text(json.dumps({**config, key: value}))
                with patch.dict(metadata["configuration"].__globals__, ROOT=self.root):
                    with self.assertRaises(ValueError):
                        metadata["configuration"]()

    def test_stale_companion_name_and_lockfile_are_rejected_and_regenerated(self):
        for filename, nested, key in [
            ("package.json", False, "name"),
            ("package-lock.json", False, "name"),
            ("package-lock.json", False, "version"),
            ("package-lock.json", True, "name"),
            ("package-lock.json", True, "version"),
            ("package-lock.json", True, "license"),
        ]:
            with self.subTest(filename=filename, nested=nested, key=key):
                path = self.root / "integrations/VSCode" / filename
                data = json.loads(path.read_text())
                target = data["packages"][""] if nested else data
                target[key] = "stale"
                path.write_text(json.dumps(data))
                result = self.run_metadata()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(filename, result.stderr)
                written = self.run_metadata("--write")
                self.assertEqual(written.returncode, 0, written.stderr)
                self.assertEqual(self.run_metadata().returncode, 0)


if __name__ == "__main__":
    unittest.main()
