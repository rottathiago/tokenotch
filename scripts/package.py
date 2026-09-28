#!/usr/bin/env python3
"""Build Tokenotch installers (drag-to-Applications DMG and /Applications PKG).

Without arguments this packages the ad-hoc signed development bundle for local
testing. Signed, notarized installers are produced only by scripts/release.py,
which reuses these builders behind the release acceptance gates. Never publishes.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
INSTALL_LOCATION = "/Applications"


def run(*args, capture=False):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def configuration():
    return json.loads((ROOT / "config/Release.json").read_text())


def package_identifier(config):
    return config["bundleID"] + ".pkg"


def artifact_name(config, kind):
    return f"{config['name']}.{kind}"


def component_plist(config):
    # A non-relocatable component always lands in /Applications instead of
    # "upgrading" a stray copy found elsewhere (for example build/Tokenotch.app).
    # Version checking refuses to downgrade over newer local storage.
    return plistlib.dumps([{
        "RootRelativeBundlePath": f"{config['name']}.app",
        "BundleIsRelocatable": False,
        "BundleIsVersionChecked": True,
        "BundleHasStrictIdentifier": True,
        "BundleOverwriteAction": "upgrade",
    }])


def distribution_xml(config, component, channel):
    name = escape(config["name"])
    identifier = escape(package_identifier(config))
    version = escape(config["version"])
    minimum = escape(config["minimumOS"])
    return f"""<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>{name}</title>
    <welcome file="welcome.txt" mime-type="text/plain"/>
    <license file="LICENSE.txt" mime-type="text/plain"/>
    <conclusion file="conclusion.txt" mime-type="text/plain"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="{minimum}"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="{identifier}"/>
        </line>
    </choices-outline>
    <choice id="default" title="{name}"/>
    <choice id="{identifier}" visible="false" title="{name}">
        <pkg-ref id="{identifier}"/>
    </choice>
    <pkg-ref id="{identifier}" version="{version}" onConclusion="none">{escape(component)}</pkg-ref>
</installer-gui-script>
"""


def installer_text(config):
    name = config["name"]
    welcome = (
        f"Welcome to {name} {config['version']}\n\n"
        f"{name} gives developers clear visibility into their AI coding usage and "
        "patterns. It tracks token consumption and model usage across GitHub Copilot "
        "CLI and Visual Studio Code sessions.\n\n"
        "A minimalist notch interface lets you run multiple coding agents at once. It "
        "alerts you when a session needs your action or attention.\n\n"
        f"{name} will be installed in {INSTALL_LOCATION}.\n\n"
        f"Requires macOS {config['minimumOS']} or later on Apple Silicon or Intel.\n\n"
        f"{name} is an independent project and is not affiliated with or endorsed by "
        f"GitHub or Microsoft.\n")
    conclusion = (
        f"{name} is ready.\n\n"
        f"Open {name} from your Applications folder. The setup guide will help you "
        "connect Copilot CLI, Visual Studio Code, or both.\n\n"
        "After setup, restart any open CLI sessions or reload VS Code windows so "
        f"{name} can begin monitoring them.\n")
    return welcome, conclusion


def installer_license():
    # Installer wraps text itself; hard line breaks inside paragraphs render as ragged lines.
    paragraphs = (ROOT / "LICENSE").read_text().strip().split("\n\n")
    def unwrap(paragraph):
        lines = [line.strip() for line in paragraph.splitlines()]
        return "\n".join(lines) if all(line.startswith("Copyright") for line in lines) else " ".join(lines)
    return "\n\n".join(unwrap(p) for p in paragraphs) + "\n"


def copy_bundle(app, destination):
    # ditto preserves the code signature, symlinks, and extended attributes.
    run("ditto", app, destination)


def build_pkg(config, app, output, channel, identity=None, keychain=None):
    """Build a product archive that installs the bundle into /Applications."""
    if output.exists():
        raise ValueError(f"Installer already exists: {output}")
    with tempfile.TemporaryDirectory(prefix="tokenotch-pkg-") as temporary:
        temporary = pathlib.Path(temporary)
        payload = temporary / "root"
        packages = temporary / "packages"
        resources = temporary / "resources"
        for directory in [payload, packages, resources]:
            directory.mkdir()
        copy_bundle(app, payload / f"{config['name']}.app")
        plist = temporary / "component.plist"
        plist.write_bytes(component_plist(config))
        component = f"{config['name']}-component.pkg"
        run("pkgbuild", "--root", payload, "--component-plist", plist,
            "--identifier", package_identifier(config), "--version", config["version"],
            "--install-location", INSTALL_LOCATION, packages / component)
        welcome, conclusion = installer_text(config)
        (resources / "welcome.txt").write_text(welcome)
        (resources / "conclusion.txt").write_text(conclusion)
        (resources / "LICENSE.txt").write_text(installer_license())
        distribution = temporary / "Distribution.xml"
        distribution.write_text(distribution_xml(config, component, channel))
        command = ["productbuild", "--distribution", distribution, "--package-path", packages,
                   "--resources", resources]
        if identity:
            command += ["--sign", identity, "--timestamp"]
            if keychain:
                command += ["--keychain", keychain]
        run(*command, output)
    return output


def build_dmg(config, app, output, identity=None, keychain=None):
    """Build a compressed drag-to-Applications disk image."""
    if output.exists():
        raise ValueError(f"Disk image already exists: {output}")
    with tempfile.TemporaryDirectory(prefix="tokenotch-dmg-") as temporary:
        stage = pathlib.Path(temporary) / config["name"]
        stage.mkdir()
        copy_bundle(app, stage / f"{config['name']}.app")
        shutil.copy2(ROOT / "LICENSE", stage / "LICENSE.txt")
        (stage / "Applications").symlink_to(INSTALL_LOCATION)
        run("hdiutil", "create", "-quiet", "-volname", config["name"], "-srcfolder", stage,
            "-fs", "HFS+", "-format", "UDZO", "-imagekey", "zlib-level=9", output)
    if identity:
        command = ["codesign", "--timestamp", "--sign", identity]
        if keychain:
            command += ["--keychain", keychain]
        run(*command, output)
    return output


def verify_bundle_identity(config, app, channel):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != config["bundleID"]:
        raise ValueError(f"Unexpected bundle identifier in {app}")
    if info.get("CFBundleShortVersionString") != config["version"]:
        raise ValueError(f"Unexpected bundle version in {app}")
    if info.get("TokenotchDistributionChannel") != channel:
        raise ValueError(f"Packaged bundle is not a {channel} build: {app}")
    run("codesign", "--verify", "--deep", "--strict", app)


def verify_pkg(config, pkg, channel):
    with tempfile.TemporaryDirectory(prefix="tokenotch-pkg-verify-") as temporary:
        expanded = pathlib.Path(temporary) / "expanded"
        run("pkgutil", "--expand-full", pkg, expanded)
        distribution = (expanded / "Distribution").read_text()
        if package_identifier(config) not in distribution or "enable_localSystem=\"true\"" not in distribution:
            raise ValueError("Installer distribution does not target the system Applications folder")
        components = list(expanded.glob("*.pkg"))
        if len(components) != 1:
            raise ValueError("Installer must contain exactly one component package")
        package_info = (components[0] / "PackageInfo").read_text()
        if f'install-location="{INSTALL_LOCATION}"' not in package_info or 'relocatable="false"' not in package_info:
            raise ValueError("Component package is relocatable or not installed to /Applications")
        verify_bundle_identity(config, components[0] / "Payload" / f"{config['name']}.app", channel)


def verify_dmg(config, dmg, channel):
    run("hdiutil", "verify", "-quiet", dmg)
    with tempfile.TemporaryDirectory(prefix="tokenotch-dmg-verify-") as mount:
        run("hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", mount, dmg)
        try:
            volume = pathlib.Path(mount)
            link = volume / "Applications"
            if not link.is_symlink() or str(link.readlink()) != INSTALL_LOCATION:
                raise ValueError("Disk image is missing the Applications shortcut")
            verify_bundle_identity(config, volume / f"{config['name']}.app", channel)
        finally:
            run("hdiutil", "detach", "-quiet", mount)


def write_checksum(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    checksum = path.with_name(path.name + ".sha256")
    checksum.write_text(f"{digest}  {path.name}\n")
    return digest


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--skip-build", action="store_true",
                        help="package the existing build/Tokenotch.app instead of running make universal")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "build/packages")
    parser.add_argument("--format", choices=["all", "dmg", "pkg"], default="all")
    args = parser.parse_args()
    config = configuration()
    if not args.skip_build:
        run("make", "universal")
    app = ROOT / "build/Tokenotch.app"
    run("python3", "scripts/verify-bundle.py", app, "--universal")
    verify_bundle_identity(config, app, "development")
    args.output.mkdir(parents=True, exist_ok=True)
    formats = ["dmg", "pkg"] if args.format == "all" else [args.format]
    targets = {kind: args.output / artifact_name(config, kind) for kind in formats}
    for target in targets.values():
        # Development installers are disposable; each build replaces the last.
        for path in [target, target.with_name(target.name + ".sha256")]:
            if path.is_symlink() or path.is_file():
                path.unlink()
            elif path.exists():
                raise ValueError(f"{path} is not a file; remove it before packaging.")
    if "dmg" in targets:
        build_dmg(config, app, targets["dmg"])
        verify_dmg(config, targets["dmg"], "development")
    if "pkg" in targets:
        build_pkg(config, app, targets["pkg"], "development")
        verify_pkg(config, targets["pkg"], "development")
    for target in targets.values():
        write_checksum(target)
        print(f"Development installer: {target.relative_to(ROOT) if target.is_relative_to(ROOT) else target}")
    print("Ad-hoc signed and NOT notarized: for local testing only. "
          "Downloaded copies are blocked by Gatekeeper; use make release for distribution.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
