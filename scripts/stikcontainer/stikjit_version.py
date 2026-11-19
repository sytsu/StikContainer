#!/usr/bin/env python3
"""Version of the bundled StikJIT framework, and version comparison.

stikjit_version.py                 print the StikJIT release the bundled framework came from
stikjit_version.py --newer A B     exit 0 if version A is newer than version B, else 1
stikjit_version.py --same A B      exit 0 if A and B are the same version (2.1 = v2.1.0), else 1

The release is read from StikJIT/VERSION, which update_stikjit.sh writes, or else from the
framework's CFBundleShortVersionString.
"""
import plistlib
import re
import sys
from pathlib import Path

VERSION_FILE = Path("StikJIT/VERSION")
FRAMEWORK_INFO = Path("StikJIT/StikJIT.xcframework/ios-arm64/StikJIT.framework/Info.plist")


def key(version):
    """Sort key for tags such as 2.0.1, v2.1 or 2.1.0-beta2 (a pre-release sorts first)."""
    version = version.strip().lstrip("vV")
    release, _, pre = version.partition("-")
    numbers = tuple(int(n) for n in re.findall(r"\d+", release))
    return numbers + (0,) * (4 - len(numbers)), pre == "", pre


def main(args):
    if args[:1] == ["--newer"] and len(args) == 3:
        return 0 if key(args[1]) > key(args[2]) else 1
    if args[:1] == ["--same"] and len(args) == 3:
        return 0 if key(args[1]) == key(args[2]) else 1
    if args:
        print(__doc__.strip(), file=sys.stderr)
        return 64
    if VERSION_FILE.is_file() and VERSION_FILE.read_text().strip():
        print(VERSION_FILE.read_text().strip())
        return 0
    with FRAMEWORK_INFO.open("rb") as f:
        print(plistlib.load(f)["CFBundleShortVersionString"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
