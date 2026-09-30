#!/usr/bin/env python3
"""Check the publishable working tree, including files not yet committed."""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RETIRED_NAME = re.compile(rb"(?:code|copilot)[ _-]?notch", re.IGNORECASE)
PRIVATE_SUFFIXES = {".p12", ".p8", ".key", ".pem", ".mobileprovision", ".provisionprofile", ".pfx", ".snk"}
ARTIFACT_SUFFIXES = {".dmg", ".pkg", ".vsix", ".zip", ".exe", ".dll", ".msi", ".msix", ".appx", ".cab", ".pdb", ".obj", ".lib"}
WINDOWS_OUTPUTS = {
    ("windows", "target"),
    ("windows", "desktop", "dist"),
    ("windows", "desktop", "src-tauri", "binaries"),
    ("windows", "desktop", "src-tauri", "gen"),
    ("windows", "test-results"),
}


def publication_paths(root):
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root, check=True, stdout=subprocess.PIPE)
    return sorted(set(pathlib.Path(path.decode("utf-8")) for path in result.stdout.split(b"\0") if path))


def project_errors(root, paths):
    errors = []
    for relative in paths:
        if relative.is_absolute() or ".." in relative.parts:
            errors.append(f"{relative}: path is outside the project")
            continue
        path = root / relative
        if path.is_symlink():
            errors.append(f"{relative}: publication must not follow a symlink")
            continue
        if not path.exists():
            continue  # A tracked deletion is not part of the next publication.
        if not path.is_file():
            errors.append(f"{relative}: expected a regular source file")
            continue
        if RETIRED_NAME.search(relative.as_posix().encode()):
            errors.append(f"{relative}: retired product name in filename")
        if (relative.parts[0] in {"site", "build", ".build", "DerivedData"}
                or any(relative.parts[:len(prefix)] == prefix for prefix in WINDOWS_OUTPUTS)
                or "node_modules" in relative.parts):
            errors.append(f"{relative}: legacy or generated tree is not publishable")
        if path.suffix.lower() in PRIVATE_SUFFIXES:
            errors.append(f"{relative}: signing material must stay outside the repository")
        if (path.suffix.lower() in ARTIFACT_SUFFIXES
                or any(part.lower().endswith(".app") for part in relative.parts)):
            errors.append(f"{relative}: build artifacts belong in ignored build output or Releases")
        if path.name == ".DS_Store":
            errors.append(f"{relative}: local filesystem metadata must not be published")
        data = path.read_bytes()
        if b"\0" not in data and RETIRED_NAME.search(data):
            errors.append(f"{relative}: retired product name in content")
    return errors


def main():
    errors = project_errors(ROOT, publication_paths(ROOT))
    if errors:
        raise ValueError("\n".join(errors))
    print("Publishable source tree uses Tokenotch identity and excludes retired distribution files.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Project check failed: {error}", file=sys.stderr)
        sys.exit(1)
