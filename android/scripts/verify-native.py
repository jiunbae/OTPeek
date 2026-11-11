#!/usr/bin/env python3
"""Inspect every packaged ELF and APK ZIP page alignment; no device/user data."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("apk", type=Path)
parser.add_argument("--sdk", type=Path, default=Path(os.environ.get(
    "ANDROID_SDK_ROOT", os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk")))))
args = parser.parse_args()
args.sdk = args.sdk.expanduser()
root = Path(__file__).resolve().parents[2]
ndk = args.sdk / "ndk/28.2.13676358/toolchains/llvm/prebuilt"
readelf = next(ndk.glob("*/bin/llvm-readelf"))
scratch = root / ".tools/verification"
scratch.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.apk) as archive, tempfile.TemporaryDirectory(dir=scratch) as temporary:
    libraries = [name for name in archive.namelist() if name.startswith("lib/") and name.endswith(".so")]
    assert libraries, "No packaged native libraries"
    assert all(name.startswith("lib/arm64-v8a/") for name in libraries), "Unexpected ABI"
    assert any(name.endswith("libotpeek_ffi.so") for name in libraries), "Rust library missing"
    assert any(name.endswith("libjnidispatch.so") for name in libraries), "JNA library missing"
    for index, name in enumerate(libraries):
        path = Path(temporary) / (str(index) + ".so")
        path.write_bytes(archive.read(name))
        output = subprocess.check_output([str(readelf), "-lW", str(path)], text=True)
        alignments = [int(line.split()[-1], 16) for line in output.splitlines() if line.strip().startswith("LOAD ")]
        assert alignments and all(value >= 16384 for value in alignments), name + ": not 16KB aligned"
        print(name + ": ELF LOAD alignment " + ",".join(map(str, alignments)))
subprocess.run([str(args.sdk / "build-tools/35.0.0/zipalign"), "-c", "-P", "16", "4", str(args.apk)], check=True)
print("ARM64 ELF + APK 16KB ZIP alignment PASS")
