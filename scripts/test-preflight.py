#!/usr/bin/env python3
import io
import pathlib
import runpy
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
preflight = runpy.run_path(str(ROOT / "scripts/preflight.py"))


class NativePrerequisites(unittest.TestCase):
    def setUp(self):
        self.outputs = {
            ("xcrun", "--find", "lipo"): "/Selected/Developer/usr/bin/lipo\n",
            ("xcrun", "--find", "swiftc"): "/Selected/Developer/usr/bin/swiftc\n",
            ("xcrun", "swiftc", "--version"): "Apple Swift version 6.1.2 (swiftlang-test)\nTarget: arm64-apple-macosx15.0\n",
            ("xcrun", "--show-sdk-path"): "/Selected/Developer/SDKs/MacOSX.sdk\n",
            ("xcrun", "--show-sdk-version"): "15.5\n",
            ("node", "--version"): "v22.12.0\n",
            ("npm", "--version"): "10.9.0\n",
            ("xcrun", "swiftc", "-swift-version", "5", "-typecheck", "-target", "arm64-apple-macosx15.0", "-"): "",
        }
        self.missing = set()
        for target, value in [("platform.system", "Darwin"), ("platform.machine", "arm64"),
                              ("platform.mac_ver", ("15.5", ("", "", ""), "arm64"))]:
            mock = patch(target, return_value=value)
            mock.start()
            self.addCleanup(mock.stop)
        finder = patch("shutil.which", side_effect=lambda tool: None if tool in self.missing else f"/ambient/bin/{tool}")
        self.finder = finder.start()
        self.addCleanup(finder.stop)
        runner = patch("subprocess.run", side_effect=self.run_tool)
        self.runner = runner.start()
        self.addCleanup(runner.stop)

    def run_tool(self, command, **kwargs):
        self.assertTrue(kwargs["check"])
        self.assertTrue(kwargs["capture_output"])
        self.assertTrue(kwargs["text"])
        self.assertEqual(kwargs["timeout"], 60 if kwargs["input"] is not None else 15)
        output = self.outputs[tuple(command)]
        if isinstance(output, Exception):
            raise output
        return subprocess.CompletedProcess(command, 0, stdout=output, stderr="")

    def test_build_checks_selected_tools_and_supported_versions_without_full_xcode(self):
        report = preflight["check"]()
        self.assertIn("Selected lipo: /Selected/Developer/usr/bin/lipo", report)
        self.assertIn("Node.js: v22.12.0", report)
        self.assertEqual(set(tuple(call.args[0]) for call in self.runner.call_args_list), set(self.outputs))
        requested = {call.args[0] for call in self.finder.call_args_list}
        self.assertEqual(requested, {"xcrun", "codesign", "git", "make", "node", "npm"})

    def test_newer_node_is_accepted(self):
        self.outputs[("node", "--version")] = "v26.5.0\n"
        self.assertIn("Node.js: v26.5.0", preflight["check"]())

    def test_missing_node_and_npm_are_actionable(self):
        self.missing.update(["node", "npm"])
        with self.assertRaises(ValueError) as error:
            preflight["check"]()
        self.assertIn("Missing required tool: node", str(error.exception))
        self.assertIn("Missing required tool: npm", str(error.exception))
        self.assertIn("Install Node.js 22.12+", str(error.exception))

    def test_old_node_swift_and_sdk_are_rejected(self):
        for command, value, expected in [
            (("node", "--version"), "v22.11.0", "Node.js 22.12.0+"),
            (("xcrun", "swiftc", "--version"), "Apple Swift version 5.10", "Swift 6.0.0+"),
            (("xcrun", "--show-sdk-version"), "14.5", "macOS SDK 15.0.0+"),
        ]:
            with self.subTest(command=command):
                original = self.outputs[command]
                self.outputs[command] = value
                with self.assertRaisesRegex(ValueError, expected.replace(".", r"\.").replace("+", r"\+")):
                    preflight["check"]()
                self.outputs[command] = original

    def test_broken_node_or_npm_installation_is_not_treated_as_present_and_working(self):
        for command in [("node", "--version"), ("npm", "--version")]:
            with self.subTest(command=command):
                original = self.outputs[command]
                self.outputs[command] = subprocess.CalledProcessError(1, command, stderr="dyld: missing library")
                with self.assertRaises(ValueError) as error:
                    preflight["check"]()
                self.assertIn("dyld: missing library", str(error.exception))
                self.assertIn("repair the installation", str(error.exception))
                self.outputs[command] = original

    def test_missing_selected_developer_tools_are_actionable(self):
        for command in [("xcrun", "--find", "lipo"), ("xcrun", "--find", "swiftc")]:
            with self.subTest(command=command):
                original = self.outputs[command]
                self.outputs[command] = subprocess.CalledProcessError(1, command, stderr="invalid developer directory")
                with self.assertRaises(ValueError) as error:
                    preflight["check"]()
                self.assertIn("invalid developer directory", str(error.exception))
                self.assertIn("DEVELOPER_DIR=", str(error.exception))
                self.outputs[command] = original

    def test_non_macos_sdk_override_is_rejected(self):
        self.outputs[("xcrun", "--show-sdk-path")] = "/Selected/SDKs/iPhoneOS.sdk\n"
        with self.assertRaisesRegex(ValueError, "A macOS SDK is required"):
            preflight["check"]()

    def test_framework_probe_detects_incompatible_swift_and_sdk_before_building(self):
        command = ("xcrun", "swiftc", "-swift-version", "5", "-typecheck", "-target", "arm64-apple-macosx15.0", "-")
        self.outputs[command] = subprocess.CalledProcessError(1, command, stderr="SDK is not supported by the compiler")
        with self.assertRaises(ValueError) as error:
            preflight["check"]()
        self.assertIn("SDK is not supported by the compiler", str(error.exception))
        self.assertIn("Clear incompatible SDKROOT/TOOLCHAINS overrides", str(error.exception))
        self.assertEqual(self.runner.call_args_list[-3].kwargs["input"],
                         "import AppKit\nimport SwiftUI\nimport SQLite3\n")

    def test_unparseable_or_empty_version_does_not_pass(self):
        for output in ["not a version", ""]:
            with self.subTest(output=output):
                self.outputs[("npm", "--version")] = output
                with self.assertRaises(ValueError) as error:
                    preflight["check"]()
                self.assertIn("npm", str(error.exception))

    def test_timed_out_tool_is_actionable(self):
        self.outputs[("node", "--version")] = subprocess.TimeoutExpired(["node", "--version"], 15)
        with self.assertRaisesRegex(ValueError, "node --version failed"):
            preflight["check"]()

    def test_unsupported_hosts_fail_before_probing_tools(self):
        with patch("platform.system", return_value="Linux"):
            with self.assertRaisesRegex(ValueError, "require macOS"):
                preflight["check"]()
        with patch("platform.mac_ver", return_value=("14.7", ("", "", ""), "arm64")):
            with self.assertRaisesRegex(ValueError, r"macOS 15\.0\.0"):
                preflight["check"]()
        with patch("sys.version_info", (3, 8, 0)):
            with self.assertRaisesRegex(ValueError, r"Python 3\.9"):
                preflight["check"]()
        self.runner.assert_not_called()

    def test_missing_xcrun_does_not_fall_back_to_ambient_lipo(self):
        self.missing.add("xcrun")
        with self.assertRaisesRegex(ValueError, "Missing required tool: xcrun"):
            preflight["check"]()
        self.assertNotIn("lipo", [call.args[0] for call in self.finder.call_args_list])
        self.assertFalse(any(call.args[0][0] == "xcrun" for call in self.runner.call_args_list))

    def test_skip_build_needs_no_compiler_node_git_or_make(self):
        self.missing.update(["node", "npm", "git", "make"])
        report = preflight["check"](package=True, skip_build=True)
        self.assertIn("Selected lipo: /Selected/Developer/usr/bin/lipo", report)
        self.assertEqual([call.args[0] for call in self.runner.call_args_list], [["xcrun", "--find", "lipo"]])
        requested = {call.args[0] for call in self.finder.call_args_list}
        self.assertEqual(requested, {"xcrun", "codesign", "ditto", "hdiutil", "pkgbuild", "productbuild", "pkgutil"})

    def test_installer_format_requires_only_its_utilities(self):
        for installer_format, unused, required in [
            ("dmg", ["pkgbuild", "productbuild", "pkgutil"], ["hdiutil"]),
            ("pkg", ["hdiutil"], ["pkgbuild", "productbuild", "pkgutil"]),
        ]:
            with self.subTest(installer_format=installer_format):
                self.missing = set(unused)
                preflight["check"](package=True, skip_build=True, installer_format=installer_format)
                self.missing.add(required[0])
                with self.assertRaisesRegex(ValueError, f"Missing required tool: {required[0]}"):
                    preflight["check"](package=True, skip_build=True, installer_format=installer_format)

    def test_cli_skip_build_requires_package(self):
        with patch("sys.argv", ["preflight.py", "--skip-build"]), redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                preflight["main"]()
        self.assertEqual(error.exception.code, 2)
        self.runner.assert_not_called()

    def test_cli_prints_versions_only_after_all_checks_pass(self):
        output = io.StringIO()
        with patch("sys.argv", ["preflight.py", "--package"]), redirect_stdout(output):
            preflight["main"]()
        self.assertIn("Native prerequisites passed", output.getvalue())
        self.missing.add("productbuild")
        output = io.StringIO()
        with patch("sys.argv", ["preflight.py", "--package"]), redirect_stdout(output):
            with self.assertRaises(ValueError):
                preflight["main"]()
        self.assertEqual(output.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
