#!/usr/bin/env python3
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

ROOT = pathlib.Path(__file__).resolve().parent.parent
package = runpy.run_path(str(ROOT / "scripts/package.py"))


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

    def test_installer_text_is_channel_independent(self):
        welcome, conclusion = package["installer_text"](self.config)
        for text in [welcome, conclusion]:
            self.assertNotIn("DEVELOPMENT", text)
            self.assertNotIn("notarized", text)

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
