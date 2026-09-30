#!/usr/bin/env python3
import copy
import contextlib
import io
import json
import os
import pathlib
import plistlib
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

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

    def test_unrecorded_acceptance_blocks_signed_release(self):
        evidence = json.loads((ROOT / "config/ReleaseAcceptance.json").read_text())
        self.assertTrue(self.errors(evidence))

    def test_unsigned_releases_do_not_require_signed_acceptance(self):
        self.assertEqual(release["gate_errors"](
            self.config, None, self.revision, self.config["repository"], False, signed=False), [])
        for revision, repository, dirty in [
            ("", self.config["repository"], False),
            ("not-a-commit", self.config["repository"], False),
            (self.revision, "other/tokenotch", False),
            (self.revision, self.config["repository"], True),
        ]:
            self.assertTrue(release["gate_errors"](
                self.config, None, revision, repository, dirty, signed=False))

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
                     patch("sys.argv", ["release.py", "--signed", "--check", "--evidence", str(evidence)]), \
                     contextlib.redirect_stdout(io.StringIO()):
                    if tag == "v" + self.config["version"]:
                        release["main"]()
                    else:
                        with self.assertRaisesRegex(ValueError, "tag must exactly match"):
                            release["main"]()

    def test_unsigned_preflight_needs_no_apple_environment_or_evidence_file(self):
        for tag in ["v" + self.config["version"], "v0.0.0"]:
            def run(*args, capture=False):
                if args == ("git", "rev-parse", "HEAD"):
                    return self.revision
                if args == ("git", "status", "--porcelain"):
                    return ""
                if args == ("git", "describe", "--tags", "--exact-match"):
                    return tag
                self.assertEqual(args[0], "python3", "Preflight must not build or sign")
            with tempfile.TemporaryDirectory(prefix="tokenotch-unsigned-check-") as temporary, \
                 patch.dict(release["main"].__globals__, run=run,
                            repository_name=lambda: self.config["repository"]), \
                 patch.dict("os.environ", {}, clear=True), \
                 patch("sys.argv", ["release.py", "--check", "--evidence", str(pathlib.Path(temporary) / "missing.json")]), \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                if tag == "v" + self.config["version"]:
                    release["main"]()
                    self.assertIn("Unsigned release prerequisites passed", output.getvalue())
                else:
                    with self.assertRaisesRegex(ValueError, "tag must exactly match"):
                        release["main"]()

    def test_signed_preflight_still_rejects_missing_credentials(self):
        def run(*args, capture=False):
            if args == ("git", "rev-parse", "HEAD"):
                return self.revision
            if args == ("git", "status", "--porcelain"):
                return ""
            self.fail("Signing prerequisites must be checked before building")
        with patch.dict(release["main"].__globals__, run=run,
                        repository_name=lambda: self.config["repository"]), \
             patch.dict("os.environ", {}, clear=True), \
             patch("sys.argv", ["release.py", "--signed", "--check"]):
            with self.assertRaises(ValueError) as failure:
                release["main"]()
            self.assertIn("Acceptance is missing", str(failure.exception))
            self.assertIn("TOKENOTCH_SIGNING_IDENTITY", str(failure.exception))
            self.assertIn("TOKENOTCH_INSTALLER_IDENTITY", str(failure.exception))
            self.assertIn("TOKENOTCH_NOTARY_PROFILE", str(failure.exception))

    def test_unsigned_packaging_keeps_verification_without_apple_services(self):
        with tempfile.TemporaryDirectory(prefix="tokenotch-unsigned-release-") as temporary:
            root = pathlib.Path(temporary)
            for directory in ["config", "docs/releases", "integrations/VSCode", "build/Tokenotch.app/Contents"]:
                (root / directory).mkdir(parents=True)
            (root / "config/Release.json").write_text(json.dumps(self.config))
            (root / f"docs/releases/{self.config['version']}.md").write_text("# Tokenotch\n\nFixture notes.\n")
            (root / "integrations/VSCode/package-lock.json").write_text(json.dumps({"packages": {}}))
            (root / "build/Tokenotch.app/Contents/Info.plist").write_bytes(
                plistlib.dumps({"TokenotchDistributionChannel": "development"}))
            commands = []

            def run(*args, capture=False):
                args = tuple(str(arg) for arg in args)
                commands.append(args)
                if args == ("git", "rev-parse", "HEAD"):
                    return self.revision
                if args == ("git", "status", "--porcelain"):
                    return ""
                if args == ("git", "describe", "--tags", "--exact-match"):
                    return "v" + self.config["version"]
                if args[0] == "ditto":
                    shutil.copytree(args[1], args[2])
                if args[:2] == ("python3", "scripts/release-config.py") and "--plist" in args:
                    path = pathlib.Path(args[args.index("--plist") + 1])
                    path.write_bytes(plistlib.dumps({
                        "TokenotchDistributionChannel": args[args.index("--distribution") + 1],
                    }))

            def build(config, app, output, *args, identity=None, keychain=None):
                self.assertIsNone(identity)
                self.assertIsNone(keychain)
                self.assertEqual(plistlib.loads((app / "Contents/Info.plist").read_bytes())[
                    "TokenotchDistributionChannel"], "release")
                if output.suffix == ".pkg":
                    self.assertEqual(args, ("release",))
                output.write_bytes(b"synthetic installer")

            def verify(config, output, channel):
                self.assertEqual(channel, "release")
                self.assertTrue(output.is_file())

            installers = release["installers"]
            notarize = Mock(side_effect=AssertionError("Unsigned packaging must not call Apple notarization"))
            with patch.dict(release["main"].__globals__, ROOT=root, run=run, notarize=notarize,
                            repository_name=lambda: self.config["repository"]), \
                 patch.object(installers, "build_dmg", side_effect=build) as dmg, \
                 patch.object(installers, "build_pkg", side_effect=build) as pkg, \
                 patch.object(installers, "verify_dmg", side_effect=verify) as verify_dmg, \
                 patch.object(installers, "verify_pkg", side_effect=verify) as verify_pkg, \
                 patch.dict("os.environ", {"TOKENOTCH_SIGNING_KEYCHAIN": "must-not-be-used"}, clear=True), \
                 patch("sys.argv", ["release.py"]), contextlib.redirect_stdout(io.StringIO()):
                release["main"]()
                dmg.assert_called_once()
                pkg.assert_called_once()
                verify_dmg.assert_called_once()
                verify_pkg.assert_called_once()
                notarize.assert_not_called()
                with self.assertRaisesRegex(ValueError, "already exists"):
                    release["main"]()
                self.assertEqual(dmg.call_count, 1, "Existing installers must not be overwritten")
            self.assertIn(("make", "test-ci", "smoke", "smoke-telemetry",
                           "smoke-history", "smoke-timeline", "smoke-notch"), commands)
            self.assertIn(("make", "universal"), commands)
            signatures = [args for args in commands if args[:2] == ("codesign", "--force")]
            self.assertEqual(len(signatures), 2)
            self.assertEqual(
                pathlib.Path(signatures[0][-1]).parts[-3:],
                ("Contents", "Helpers", "TokenotchHook"),
            )
            self.assertEqual(pathlib.Path(signatures[1][-1]).name, "Tokenotch.app")
            for signature in signatures:
                self.assertEqual(signature[signature.index("--sign") + 1], "-")
                self.assertNotIn("--timestamp", signature)
                self.assertNotIn("--keychain", signature)
            self.assertTrue(any(args[:4] == ("codesign", "--verify", "--deep", "--strict") for args in commands))
            self.assertFalse(any("spctl" in args or "notarytool" in args or "stapler" in args for args in commands))
            output = root / "build/releases"
            inventory = json.loads((output / f"Tokenotch-{self.config['version']}-inventory.json").read_text())
            self.assertEqual(inventory["signing"], "ad-hoc")
            self.assertIs(inventory["notarized"], False)
            self.assertIsNone(inventory["signingTeam"])
            self.assertIsNone(inventory["acceptance"])
            self.assertEqual(inventory["sourceRevision"], self.revision)
            self.assertEqual(set(inventory["artifacts"]), {"Tokenotch.dmg", "Tokenotch.pkg"})
            notes = (output / "release-notes.md").read_text()
            self.assertIn("unsigned and have not been notarized", notes)
            self.assertIn(self.revision, notes)
            for name, digest in inventory["artifacts"].items():
                self.assertIn(f"{digest}  {name}", notes)
                self.assertEqual((output / f"{name}.sha256").read_text().strip(), f"{digest}  {name}")

    def test_workflow_defaults_to_regular_unsigned_releases_with_two_assets(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("type: boolean\n        default: false", workflow)
        self.assertIn("if: ${{ !inputs.signed }}\n        run: make release", workflow)
        self.assertIn("make release RELEASE_ARGS=--signed", workflow)
        command = shlex.split(workflow[workflow.index('gh release create "$RELEASE_TAG"'):].replace("\\\n", ""))
        self.assertIn("--verify-tag", command)
        self.assertIn("--draft", command)
        self.assertIn("--prerelease=false", command)
        self.assertEqual(command[command.index("--notes-file") + 1], "build/releases/release-notes.md")
        self.assertEqual(command[-2:], ["build/releases/Tokenotch.dmg", "build/releases/Tokenotch.pkg"])
        self.assertFalse(any(".sha256" in part or "-inventory.json" in part for part in command))


class ReleaseNotesChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenotch-notes-cli-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        for relative in ["config/Release.json", "scripts/release.py", "scripts/package.py"]:
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        self.config = json.loads((self.root / "config/Release.json").read_text())
        self.notes = self.root / f"docs/releases/{self.config['version']}.md"
        self.notes.parent.mkdir(parents=True)

    def run_notes(self, *args):
        return subprocess.run(
            [sys.executable, str(self.root / "scripts/release.py"), "--check-notes", *args],
            cwd=self.root, check=False, capture_output=True, text=True,
            env={"PATH": os.environ["PATH"]})

    def test_cli_accepts_current_notes_without_git_or_apple_configuration(self):
        self.notes.write_text("# Tokenotch\n\nFixture release notes.\n")
        result = self.run_notes()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.notes.relative_to(self.root)), result.stdout)
        self.assertIn("Release preflight has not run", result.stdout)

    def test_cli_rejects_missing_empty_and_renamed_current_notes(self):
        for content in [None, "", " \t\n"]:
            with self.subTest(content=content):
                if content is not None:
                    self.notes.write_text(content)
                result = self.run_notes()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Release blocked: Add nonempty release notes", result.stderr)
        self.notes.write_text("# Tokenotch\n\nFixture release notes.\n")
        self.notes.rename(self.notes.with_name("other-version.md"))
        result = self.run_notes()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Add nonempty release notes", result.stderr)

    def test_notes_only_does_not_invoke_release_prerequisites(self):
        self.notes.write_text("# Tokenotch\n\nFixture release notes.\n")
        unexpected = Mock(side_effect=AssertionError("Notes validation must not run release prerequisites"))
        with patch.dict(release["main"].__globals__, ROOT=self.root, run=unexpected,
                        repository_name=unexpected, notarize=unexpected), \
             patch.dict("os.environ", {"TOKENOTCH_RELEASE_EVIDENCE": str(self.root / "missing.json")},
                        clear=True), \
             patch("sys.argv", ["release.py", "--check-notes"]), \
             contextlib.redirect_stdout(io.StringIO()):
            release["main"]()
        unexpected.assert_not_called()

    def test_cli_rejects_release_mode_combinations(self):
        self.notes.write_text("# Tokenotch\n\nFixture release notes.\n")
        for args in [("--check",), ("--signed",), ("--evidence", "acceptance.json")]:
            with self.subTest(args=args):
                result = self.run_notes(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("--check-notes", result.stderr)

    def test_required_docs_job_runs_metadata_and_python_regressions_unconditionally(self):
        workflow = (ROOT / ".github/workflows/docs.yml").read_text()
        docs_job = workflow.split("\n  docs:\n", 1)[1]
        job_settings, steps = docs_job.split("\n    steps:\n", 1)
        self.assertIn("runs-on: ubuntu-latest", job_settings)
        self.assertNotIn("if:", job_settings)
        self.assertNotIn("continue-on-error:", job_settings)
        for command in ["make metadata", "python3 scripts/test-release.py",
                        "python3 scripts/test-project.py"]:
            matching = [step for step in steps.split("\n      - ") if command in step]
            self.assertEqual(len(matching), 1, command)
            self.assertNotIn("if:", matching[0])
            self.assertNotIn("continue-on-error:", matching[0])
        makefile = (ROOT / "Makefile").read_text()
        target = makefile.split("\nmetadata:\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn("\tpython3 scripts/release.py --check-notes\n", target)
        self.assertIn("\tpython3 scripts/check-project.py", target)


class ReleaseMetadata(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenotch-metadata-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        for relative in ["config/Release.json", "config/Release.xcconfig",
                         "sources/Core/TokenotchProduct.swift", "integrations/VSCode/src/product.cjs",
                         "integrations/VSCode/package.json", "integrations/VSCode/package-lock.json",
                         "windows/config/release.json", "windows/config/desktop.json",
                         "windows/config/minimum-build.nsh",
                         "windows/core/src/product.rs", "windows/desktop/src/product.js",
                         "windows/desktop/src-tauri/tauri.conf.json",
                         "LICENSE", "integrations/VSCode/LICENSE", "scripts/release-config.py"]:
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)

    def run_metadata(self, *args):
        return subprocess.run([sys.executable, str(self.root / "scripts/release-config.py"), *args],
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

    def test_windows_generated_identity_is_checked_and_repaired(self):
        for filename in ["windows/core/src/product.rs", "windows/desktop/src/product.js",
                         "windows/desktop/src-tauri/tauri.conf.json", "windows/config/minimum-build.nsh"]:
            path = self.root / filename
            path.write_text("stale\n")
            self.assertNotEqual(self.run_metadata().returncode, 0)
            self.assertEqual(self.run_metadata("--write").returncode, 0)
            self.assertEqual(self.run_metadata().returncode, 0)

    def test_windows_targets_and_channel_cannot_be_silently_removed(self):
        path = self.root / "windows/config/release.json"
        original = json.loads(path.read_text())
        for key, value in [("architectures", ["x64"]), ("minimumWindowsBuild", True),
                           ("minimumWindowsBuild", 19045), ("channel", "release"),
                           ("dataDirectory", "../other"), ("installMode", "perMachine")]:
            path.write_text(json.dumps({**original, key: value}))
            self.assertNotEqual(self.run_metadata().returncode, 0, (key, value))

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
