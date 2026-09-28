#!/usr/bin/env python3
"""Fail-closed Developer ID packaging. Never publishes a release."""
import argparse
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("tokenotch_package", ROOT / "scripts/package.py")
installers = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(installers)
GATES = [
    "approvedByOwner", "ownershipAndLicensingVerified", "appleSiliconAccepted",
    "intelAccepted", "cliAccepted", "vscodeAccepted",
    "accessibilityAccepted", "performanceAccepted", "securityReviewAccepted",
]


def run(*args, capture=False):
    result = subprocess.run(args, cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def gate_errors(config, evidence, revision, repository, dirty):
    errors = []
    if repository != config["repository"]:
        errors.append("Release must run from the configured owned repository.")
    if dirty:
        errors.append("Release requires a clean committed source tree.")
    if not re.fullmatch(r"[0-9a-f]{40}", revision) or evidence.get("sourceRevision") != revision:
        errors.append("Acceptance evidence must name the exact source revision being released.")
    for gate in GATES:
        if evidence.get(gate) is not True:
            errors.append(f"Acceptance is missing: {gate}")
    return errors


def repository_name():
    if os.environ.get("GITHUB_REPOSITORY"):
        return os.environ["GITHUB_REPOSITORY"]
    result = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT,
                            capture_output=True, text=True)
    remote = result.stdout.strip()
    for prefix in ["https://github.com/", "git@github.com:"]:
        if remote.startswith(prefix):
            return remote[len(prefix):].removesuffix(".git")
    return ""


def notarize(path):
    command = ["xcrun", "notarytool", "submit", str(path), "--wait", "--timeout", "20m",
               "--output-format", "json", "--keychain-profile", os.environ["TOKENOTCH_NOTARY_PROFILE"]]
    if os.environ.get("TOKENOTCH_SIGNING_KEYCHAIN"):
        command += ["--keychain", os.environ["TOKENOTCH_SIGNING_KEYCHAIN"]]
    result = json.loads(run(*command, capture=True))
    if result.get("status") != "Accepted":
        raise ValueError("Apple did not accept notarization. Review the submission in notarytool.")


def release_notes(config):
    path = ROOT / "docs/releases" / f"{config['version']}.md"
    if not path.is_file() or not path.read_text().strip():
        raise ValueError("Add nonempty release notes for the configured version in docs/releases.")
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--evidence", type=pathlib.Path,
                        default=pathlib.Path(os.environ.get("TOKENOTCH_RELEASE_EVIDENCE", ROOT / "config/ReleaseAcceptance.json")))
    args = parser.parse_args()
    config = json.loads((ROOT / "config/Release.json").read_text())
    evidence = json.loads(args.evidence.read_text())
    revision = run("git", "rev-parse", "HEAD", capture=True)
    dirty = bool(run("git", "status", "--porcelain", capture=True))
    errors = gate_errors(config, evidence, revision, repository_name(), dirty)
    identity = os.environ.get("TOKENOTCH_SIGNING_IDENTITY", "")
    team = os.environ.get("TOKENOTCH_TEAM_ID", "")
    installer_identity = os.environ.get("TOKENOTCH_INSTALLER_IDENTITY", "")
    keychain = os.environ.get("TOKENOTCH_SIGNING_KEYCHAIN") or None
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", identity):
        errors.append("Set TOKENOTCH_SIGNING_IDENTITY to an owned Developer ID Application certificate fingerprint.")
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", installer_identity):
        errors.append("Set TOKENOTCH_INSTALLER_IDENTITY to an owned Developer ID Installer certificate fingerprint.")
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        errors.append("Set TOKENOTCH_TEAM_ID to the verified Apple developer team.")
    if not os.environ.get("TOKENOTCH_NOTARY_PROFILE"):
        errors.append("Configure a notarytool keychain profile and TOKENOTCH_NOTARY_PROFILE.")
    if errors:
        raise ValueError("\n".join(errors))
    run("python3", "scripts/release-config.py")
    run("python3", "scripts/make-brand-assets.py", "--check")
    run("python3", "scripts/check-project.py")
    release_notes(config)
    tag = "v" + config["version"]
    if run("git", "describe", "--tags", "--exact-match", capture=True) != tag:
        raise ValueError("Release tag must exactly match the configured version.")
    if args.check:
        print("Release prerequisites are recorded; signing and artifact acceptance still run during packaging.")
        return
    run("make", "test-ci", "smoke", "smoke-telemetry", "smoke-history", "smoke-timeline", "smoke-notch")
    run("make", "universal")
    run("python3", "scripts/verify-bundle.py", "build/Tokenotch.app", "--universal")
    output = ROOT / "build/releases"
    output.mkdir(parents=True, exist_ok=True)
    dmg = output / installers.artifact_name(config, "dmg")
    pkg = output / installers.artifact_name(config, "pkg")
    for artifact in [dmg, pkg]:
        if artifact.exists():
            raise ValueError("Release artifact already exists. Preserve or explicitly remove it before retrying.")
    with tempfile.TemporaryDirectory(prefix="tokenotch-release-") as temporary:
        app = pathlib.Path(temporary) / "Tokenotch.app"
        run("ditto", str(ROOT / "build/Tokenotch.app"), str(app))
        run("python3", "scripts/release-config.py", "--plist", str(app / "Contents/Info.plist"),
            "--distribution", "release")
        run("python3", "scripts/verify-bundle.py", str(app), "--universal", "--release")
        for target in [app / "Contents/Helpers/TokenotchHook", app]:
            command = ["codesign", "--force", "--timestamp", "--options", "runtime", "--sign", identity]
            if keychain:
                command += ["--keychain", keychain]
            run(*command, str(target))
        detail = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], check=True,
                                capture_output=True, text=True).stderr
        if f"TeamIdentifier={team}" not in detail or "Authority=Developer ID Application:" not in detail:
            raise ValueError("Signed application does not have the required Developer ID team identity.")
        run("codesign", "--verify", "--deep", "--strict", str(app))
        archive = pathlib.Path(temporary) / "Tokenotch.zip"
        run("ditto", "-c", "-k", "--keepParent", str(app), str(archive))
        notarize(archive)
        run("xcrun", "stapler", "staple", str(app))
        run("xcrun", "stapler", "validate", str(app))
        run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
        installers.build_dmg(config, app, dmg, identity=identity, keychain=keychain)
        notarize(dmg)
        run("xcrun", "stapler", "staple", str(dmg))
        run("xcrun", "stapler", "validate", str(dmg))
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", str(dmg))
        installers.verify_dmg(config, dmg, "release")
        installers.build_pkg(config, app, pkg, "release", identity=installer_identity, keychain=keychain)
        signature = run("pkgutil", "--check-signature", str(pkg), capture=True)
        if "Developer ID Installer:" not in signature or f"({team})" not in signature:
            raise ValueError("Installer package does not have the required Developer ID Installer team identity.")
        notarize(pkg)
        run("xcrun", "stapler", "staple", str(pkg))
        run("xcrun", "stapler", "validate", str(pkg))
        run("spctl", "--assess", "--type", "install", "--verbose=2", str(pkg))
        installers.verify_pkg(config, pkg, "release")
    digests = {artifact.name: installers.write_checksum(artifact) for artifact in [dmg, pkg]}
    lock = json.loads((ROOT / "integrations/VSCode/package-lock.json").read_text())
    inventory = {
        "product": config, "sourceRevision": revision, "architectures": ["arm64", "x86_64"],
        "artifactSHA256": digests[dmg.name], "artifacts": digests, "signingTeam": team,
        "acceptance": evidence,
        "swiftPackages": [], "runtime": "macOS system frameworks; Node built-ins in the companion",
        "buildDependencies": [
            {"path": name, "version": package.get("version"), "license": package.get("license", "not reported"),
             "integrity": package.get("integrity")}
            for name, package in lock["packages"].items() if name
        ],
    }
    (output / f"Tokenotch-{config['version']}-inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    print(f"Verified release artifacts: {output}. Nothing has been published.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Release blocked: {error}", file=sys.stderr)
        sys.exit(1)
