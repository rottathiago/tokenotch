#!/usr/bin/env python3
import pathlib
import runpy
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
project = runpy.run_path(str(ROOT / "scripts/check-project.py"))


class PublicationChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenotch-publication-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)

    def write(self, name, data=b"Tokenotch\n"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return pathlib.Path(name)

    def errors(self, *paths):
        return project["project_errors"](self.root, paths)

    def test_clean_source_and_attribution(self):
        paths = [self.write("sources/App/TokenotchMain.swift"),
                 self.write("LICENSE", b"Copyright (c) 2026 Vinz\nMIT License\n"),
                 self.write("sources/Resources/Brand/Tokenotch.png", b"\x89PNG\0")]
        self.assertEqual(self.errors(*paths), [])

    def test_retired_names_in_content_and_filenames(self):
        for prefix in ["code", "copilot"]:
            for separator in ["", "-", "_", " "]:
                name = prefix + separator + "notch"
                with self.subTest(name=name):
                    self.assertTrue(self.errors(self.write("README.md", name.upper().encode())))
                    self.assertTrue(self.errors(self.write(f"{name}.png", b"\0")))

    def test_legacy_trees_and_build_or_signing_artifacts(self):
        for name in ["windows/Cargo.toml", "site/feed.xml", ".github/release.p12",
                     "notary.p8", "certificate.pem", "signing.key", "Tokenotch.dmg",
                     "Tokenotch.pkg", "Tokenotch.zip", "TokenotchVSCode.vsix",
                     "Tokenotch.app/Contents/MacOS/Tokenotch", ".DS_Store",
                     "build/generated.swift", ".build/cache.json", "DerivedData/build.log",
                     "integrations/VSCode/node_modules/package/index.js"]:
            with self.subTest(name=name):
                self.assertTrue(self.errors(self.write(name)))

    def test_deleted_files_do_not_block_publication(self):
        self.assertEqual(self.errors(pathlib.Path("windows/README.md")), [])

    def test_documentation_paths_obey_publication_rules(self):
        retired = b"code" + b" notch"
        for name, data, expected in [
            ("docs/features.md", retired, "retired product name in content"),
            ("docs/.DS_Store", b"synthetic metadata", "local filesystem metadata"),
            ("docs/example.pem", b"synthetic signing fixture", "signing material"),
            ("docs/example.dmg", b"synthetic installer", "build artifacts"),
            ("scripts/docs/node_modules/example/index.js", b"synthetic dependency",
             "legacy or generated tree"),
        ]:
            with self.subTest(name=name):
                errors = self.errors(self.write(name, data))
                self.assertTrue(any(expected in error for error in errors), errors)

    def test_symlinks_and_outside_paths_are_not_read(self):
        (self.root / "linked.swift").symlink_to(self.root / "missing.swift")
        self.assertTrue(self.errors(pathlib.Path("linked.swift")))
        self.assertTrue(self.errors(pathlib.Path("../outside")))
        self.assertTrue(self.errors(self.root / "absolute"))

    def test_git_inventory_includes_untracked_hidden_files_and_tracked_ignored_files(self):
        def git(*args):
            subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)
        git("init", "--quiet")
        self.write(".gitignore", b"build/\n")
        tracked = self.write("build/previous.pkg")
        git("add", "--force", tracked.as_posix())
        self.write("build/local.pkg")
        hidden = self.write(".github/workflows/ci.yml")
        untracked = self.write("README.md")
        paths = project["publication_paths"](self.root)
        self.assertIn(tracked, paths)
        self.assertIn(hidden, paths)
        self.assertIn(untracked, paths)
        self.assertNotIn(pathlib.Path("build/local.pkg"), paths)
        self.assertTrue(project["project_errors"](self.root, paths))


if __name__ == "__main__":
    unittest.main()
