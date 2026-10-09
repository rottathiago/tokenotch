#!/usr/bin/env python3
import io
import json
import pathlib
import plistlib
import runpy
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ElementTree
import zipfile
from contextlib import redirect_stdout
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
package = runpy.run_path(str(ROOT / "scripts/package.py"))


class PackagingPreflight(unittest.TestCase):
    def test_prerequisite_failure_stops_before_build_or_output_changes(self):
        for skip_build in [False, True]:
            with self.subTest(skip_build=skip_build), tempfile.TemporaryDirectory(prefix="tokenotch-preflight-package-") as temporary:
                output = pathlib.Path(temporary) / "packages"
                args = ["package.py", "--format", "pkg", "--output", str(output)]
                if skip_build:
                    args.append("--skip-build")

                def fail(*command):
                    raise subprocess.CalledProcessError(1, command)

                with patch("sys.argv", args), \
                     patch.dict(package["main"].__globals__, run=fail):
                    with self.assertRaises(subprocess.CalledProcessError) as error:
                        package["main"]()
                expected = ("python3", "scripts/preflight.py", "--package", "--format", "pkg")
                if skip_build:
                    expected += ("--skip-build",)
                self.assertEqual(error.exception.cmd, expected)
                self.assertFalse(output.exists())

    def test_preflight_runs_before_universal_build_and_bundle_checks(self):
        commands = []
        with tempfile.TemporaryDirectory(prefix="tokenotch-preflight-order-") as temporary:
            with patch("sys.argv", ["package.py", "--format", "dmg", "--output", temporary]), \
                 patch.dict(package["main"].__globals__,
                            run=lambda *command: commands.append(command),
                            verify_bundle_identity=lambda *args: None,
                            build_dmg=lambda *args: None,
                            verify_dmg=lambda *args: None,
                            write_checksum=lambda *args: "synthetic"), redirect_stdout(io.StringIO()):
                package["main"]()
        self.assertEqual(commands[:2], [
            ("python3", "scripts/preflight.py", "--package", "--format", "dmg"),
            ("make", "universal"),
        ])
        self.assertEqual(commands[2][:2], ("python3", "scripts/verify-bundle.py"))


class InstallerMetadata(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((ROOT / "config/Release.json").read_text())

    def distribution(self, channel="release"):
        return ElementTree.fromstring(package["distribution_xml"](self.config, "Tokenotch-component.pkg", channel))

    def test_component_is_pinned_to_applications_and_refuses_downgrades(self):
        [component] = plistlib.loads(package["component_plist"](self.config))
        self.assertEqual(component["RootRelativeBundlePath"], "Tokenotch.app")
        self.assertIs(component["BundleIsRelocatable"], False)
        self.assertIs(component["BundleIsVersionChecked"], True)
        self.assertIs(component["BundleHasStrictIdentifier"], True)
        self.assertEqual(package["INSTALL_LOCATION"], "/Applications")

    def test_distribution_targets_the_local_system_only(self):
        domains = self.distribution().find("domains").attrib
        self.assertEqual(domains, {"enable_anywhere": "false", "enable_currentUserHome": "false",
                                   "enable_localSystem": "true"})

    def test_distribution_enforces_minimum_os_and_architectures(self):
        root = self.distribution()
        self.assertEqual(root.find("volume-check/allowed-os-versions/os-version").get("min"),
                         self.config["minimumOS"])
        self.assertEqual(root.find("options").get("hostArchitectures"), "arm64,x86_64")
        self.assertEqual(root.find("options").get("require-scripts"), "false")

    def test_distribution_references_the_versioned_component(self):
        reference = self.distribution().find("pkg-ref[@version]")
        self.assertEqual(reference.get("id"), self.config["bundleID"] + ".pkg")
        self.assertEqual(reference.get("version"), self.config["version"])
        self.assertEqual(reference.text, "Tokenotch-component.pkg")

    def test_installer_is_named_tokenotch_only(self):
        self.assertEqual(package["artifact_name"](self.config, "pkg"), "Tokenotch.pkg")
        self.assertEqual(package["artifact_name"](self.config, "dmg"), "Tokenotch.dmg")
        for channel in ["development", "release"]:
            self.assertEqual(self.distribution(channel).find("title").text, "Tokenotch")

    def test_unsigned_installer_text_discloses_the_actual_signing_status(self):
        welcome, conclusion = package["installer_text"](self.config)
        for text in [welcome, conclusion]:
            self.assertNotIn("DEVELOPMENT", text)
        self.assertIn("unsigned and have not been notarized by Apple", welcome)
        self.assertIn("ad-hoc signing, not a verified Developer ID", welcome)
        self.assertIn("Privacy & Security > Open Anyway", welcome)
        self.assertIn(f"https://github.com/{self.config['repository']}/releases", welcome)
        self.assertIn("Do not disable Gatekeeper or remove quarantine", welcome)

    def test_signed_installer_text_does_not_claim_unsigned_distribution(self):
        welcome, conclusion = package["installer_text"](self.config, signed=True)
        self.assertNotIn("unsigned", welcome)
        self.assertIn("Applications", welcome)
        self.assertIn("Applications", conclusion)

    def test_unsigned_dmg_includes_a_disclosure_file(self):
        for signed in [False, True]:
            with self.subTest(signed=signed), tempfile.TemporaryDirectory(prefix="tokenotch-dmg-stage-test-") as temporary:
                output = pathlib.Path(temporary) / "Tokenotch.dmg"
                notices = []

                def run(*args, capture=False):
                    if args[:2] == ("hdiutil", "create"):
                        stage = pathlib.Path(args[args.index("-srcfolder") + 1])
                        notice = stage / "UNSIGNED.txt"
                        notices.append(notice.read_text() if notice.exists() else None)

                with patch.dict(package["build_dmg"].__globals__, run=run,
                                copy_bundle=lambda source, destination: destination.mkdir()):
                    package["build_dmg"](self.config, pathlib.Path(temporary) / "Tokenotch.app",
                                         output, identity="synthetic-certificate" if signed else None)
                self.assertEqual(notices, [None if signed else package["unsigned_notice"](self.config) + "\n"])

    def test_installer_license_keeps_paragraphs_without_hard_wraps(self):
        license_text = package["installer_license"]()
        paragraphs = license_text.strip().split("\n\n")
        self.assertTrue(all("\n" not in paragraph for paragraph in paragraphs
                            if not paragraph.startswith("Copyright")))
        self.assertIn("Copyright (c) 2026 Vinz\nCopyright (c) 2026 rottathiago", license_text)
        original = (ROOT / "LICENSE").read_text()
        self.assertEqual(license_text.split(), original.split())


class BundleContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenotch-bundle-test-")
        self.addCleanup(self.temporary.cleanup)
        self.app = pathlib.Path(self.temporary.name) / "Tokenotch.app"
        self.contents = self.app / "Contents"
        self.resources = self.contents / "Resources"
        self.resources.mkdir(parents=True)
        subprocess.run(["python3", str(ROOT / "scripts/release-config.py"),
                        "--plist", str(self.contents / "Info.plist")], check=True, capture_output=True)
        for name in ["MacOS/Tokenotch", "Helpers/TokenotchHook", "Resources/CopilotUsage/extension.mjs"]:
            path = self.contents / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic fixture\n")
        for source in [ROOT / "LICENSE", ROOT / "config/Release.json",
                       *list((ROOT / "sources/Resources/Brand").iterdir())]:
            shutil.copy2(source, self.resources / source.name)
        self.companion = {
            "extension/package.json": (ROOT / "integrations/VSCode/package.json").read_bytes(),
            "extension/LICENSE.txt": (ROOT / "LICENSE").read_bytes(),
            "extension/icon.png": (ROOT / "integrations/VSCode/icon.png").read_bytes(),
            "extension/src/product.cjs": (ROOT / "integrations/VSCode/src/product.cjs").read_bytes(),
        }
        self.write_companion()

    def write_companion(self):
        with zipfile.ZipFile(self.resources / "TokenotchVSCode.vsix", "w") as archive:
            for name, data in self.companion.items():
                archive.writestr(name, data)

    def verify(self):
        return subprocess.run(["python3", str(ROOT / "scripts/verify-bundle.py"), str(self.app)],
                              capture_output=True, text=True)

    def test_complete_bundle_contract(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def universal_commands(self):
        return [
            ["xcrun", "lipo", str(self.contents / binary), "-verify_arch", architecture]
            for binary in ["MacOS/Tokenotch", "Helpers/TokenotchHook"]
            for architecture in ["arm64", "x86_64"]
        ]

    def test_universal_checks_each_architecture_of_both_binaries_with_selected_toolchain(self):
        output = io.StringIO()
        with patch("sys.argv", ["verify-bundle.py", str(self.app), "--universal"]), \
             patch("subprocess.run") as run, redirect_stdout(output):
            runpy.run_path(str(ROOT / "scripts/verify-bundle.py"))
        self.assertEqual([call.args[0] for call in run.call_args_list], self.universal_commands())
        self.assertTrue(all(call.kwargs["check"] for call in run.call_args_list))
        self.assertIn("verified", output.getvalue())

    def test_missing_slice_in_either_binary_stops_universal_verification(self):
        for rejected in self.universal_commands():
            with self.subTest(command=rejected):
                output = io.StringIO()

                def run(command, **kwargs):
                    if command == rejected:
                        raise subprocess.CalledProcessError(1, command)

                with patch("sys.argv", ["verify-bundle.py", str(self.app), "--universal"]), \
                     patch("subprocess.run", side_effect=run) as runner, redirect_stdout(output):
                    with self.assertRaises(subprocess.CalledProcessError):
                        runpy.run_path(str(ROOT / "scripts/verify-bundle.py"))
                self.assertEqual(runner.call_args.args[0], rejected)
                self.assertNotIn("verified", output.getvalue())

    def test_unavailable_selected_toolchain_does_not_report_success(self):
        output = io.StringIO()
        with patch("sys.argv", ["verify-bundle.py", str(self.app), "--universal"]), \
             patch("subprocess.run", side_effect=FileNotFoundError("xcrun")), redirect_stdout(output):
            with self.assertRaises(FileNotFoundError):
                runpy.run_path(str(ROOT / "scripts/verify-bundle.py"))
        self.assertNotIn("verified", output.getvalue())

    def test_non_universal_verification_does_not_require_lipo(self):
        with patch("sys.argv", ["verify-bundle.py", str(self.app)]), \
             patch("subprocess.run") as run, redirect_stdout(io.StringIO()):
            runpy.run_path(str(ROOT / "scripts/verify-bundle.py"))
        run.assert_not_called()

    def test_missing_executable_is_rejected(self):
        (self.contents / "MacOS/Tokenotch").unlink()
        self.assertIn("Missing bundle resource", self.verify().stderr)

    def test_bundle_names_match_product(self):
        path = self.contents / "Info.plist"
        original = plistlib.loads(path.read_bytes())
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"]:
            path.write_bytes(plistlib.dumps({**original, key: "OtherProduct"}))
            self.assertIn(key, self.verify().stderr)

    def test_missing_attribution_is_rejected(self):
        (self.resources / "LICENSE").write_text("MIT\n")
        self.assertIn("attribution mismatch", self.verify().stderr)

    def test_stale_embedded_release_identity_is_rejected(self):
        path = self.resources / "Release.json"
        config = json.loads(path.read_text())
        path.write_text(json.dumps({**config, "build": "999"}))
        self.assertIn("release identity is stale", self.verify().stderr)

    def test_companion_name_and_runtime_identity_are_verified(self):
        original = self.companion["extension/package.json"]
        package = json.loads(original)
        package["name"] = "other-companion"
        self.companion["extension/package.json"] = json.dumps(package).encode()
        self.write_companion()
        self.assertIn("companion name is stale", self.verify().stderr)
        self.companion["extension/package.json"] = original
        self.companion["extension/src/product.cjs"] = b"module.exports = {};\n"
        self.write_companion()
        self.assertIn("companion identity is stale", self.verify().stderr)


if __name__ == "__main__":
    unittest.main()
