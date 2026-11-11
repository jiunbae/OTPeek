"""Read-only checks of the actual MSIX upload payload; no signing or submission.

Uses Python's standard library. Does not replace MakeAppx or WACK on Windows.
"""

import argparse
import io
import json
import re
import struct
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path


class PackageError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise PackageError(message)


def pe_machine(data):
    require(len(data) >= 64 and data[:2] == b"MZ", "Invalid PE DOS header")
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    require(offset + 6 <= len(data), "Truncated PE header")
    require(data[offset:offset + 4] == b"PE\0\0", "Invalid PE signature")
    return struct.unpack_from("<H", data, offset + 4)[0]


def verify(path, name, publisher, display_name, version, architectures, preview_identity=False,
           required_resource_scales=()):
    if not preview_identity:
        require(name not in {"Otpeek", "OtpAuthenticator"}, "Placeholder package name")
        require(publisher not in {"CN=Otpeek", "CN=OtpAuthenticator"}, "Placeholder publisher")
    require(re.fullmatch(r"[A-Za-z0-9.-]{3,50}", name), "Invalid package name")
    require(publisher.startswith("CN=") and display_name.strip(), "Expected Store identity required")
    require(re.fullmatch(r"\d+\.\d+\.\d+\.0", version), "Version must end in .0")
    require(all(int(v) <= 65535 for v in version.split(".")), "Version component exceeds 65535")
    require(int(version.split(".")[0]) >= 1, "Version major must be positive")
    expected = {"Name": name, "Publisher": publisher, "Version": version}
    found = []
    resource_scales = set()

    def identity(element, fields, label):
        require(element is not None, f"Missing identity: {label}")
        require(all(element.get(k) == v for k, v in fields.items()), f"Identity mismatch: {label}")

    def visit(data, label, kind):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            names = archive.namelist()
            require(len(names) == len(set(names)), f"Duplicate ZIP entries: {label}")
            require(not any(Path(n).suffix.lower() in {".pfx", ".p12", ".key"} for n in names),
                    f"Private-key file extension in package: {label}")
            if kind == "upload":
                children = [n for n in names if n.lower().endswith((".msixbundle", ".appxbundle", ".msix", ".appx"))]
                require(children, "Upload contains no package or bundle")
                for child in children:
                    visit(archive.read(child), child, "bundle" if child.lower().endswith("bundle") else "package")
                return
            if kind == "bundle":
                manifest = ET.fromstring(archive.read("AppxMetadata/AppxBundleManifest.xml"))
                # Bundle versions can be generated separately; application versions must match.
                identity(manifest.find("{*}Identity"), {"Name": name, "Publisher": publisher}, label)
                packages = manifest.findall("{*}Packages/{*}Package")
                require(packages, "Bundle manifest has no packages")
                listed = [p.get("FileName") for p in packages]
                actual = [n for n in names if n.lower().endswith((".msix", ".appx"))]
                require(set(listed) == set(actual), "Bundle manifest/package entries differ")
                for child in listed:
                    visit(archive.read(child), child, "package")
                return
            manifest = ET.fromstring(archive.read("AppxManifest.xml"))
            for resource in manifest.findall("{*}Resources/{*}Resource"):
                for attribute, value in resource.attrib.items():
                    if attribute.rsplit("}", 1)[-1] == "Scale":
                        resource_scales.add(str(value))
            ident = manifest.find("{*}Identity")
            identity(ident, expected, label)
            require(manifest.findtext("{*}Properties/{*}PublisherDisplayName") == display_name,
                    f"Publisher display name mismatch: {label}")
            if manifest.find("{*}Properties/{*}ResourcePackage") is not None:
                resource = manifest.findtext("{*}Properties/{*}ResourcePackage")
                if resource and resource.strip().lower() == "true":
                    return
            arch = ident.get("ProcessorArchitecture")
            require(arch in architectures, f"Unexpected architecture: {arch}")
            machine = {"x64": 0x8664, "arm64": 0xAA64, "x86": 0x14C}[arch]
            required = {"Otpeek.exe", "otpeek_ffi.dll", "Otpeek.Widget.exe",
                        "Otpeek.Widget.dll", "Otpeek.Widget.deps.json", "Otpeek.Widget.runtimeconfig.json"}
            require(required <= set(names), f"Missing app/core/widget payload: {label}")
            runtime_files = {"coreclr.dll", "clrjit.dll", "hostfxr.dll", "hostpolicy.dll", "System.Private.CoreLib.dll"}
            require(runtime_files <= set(names), f"Missing bundled .NET runtime: {label}")
            for config in ("Otpeek.runtimeconfig.json", "Otpeek.Widget.runtimeconfig.json"):
                options = json.loads(archive.read(config)).get("runtimeOptions", {})
                require(not options.get("framework") and not options.get("frameworks"),
                        f"External .NET framework required: {config}")
                require(any(f.get("name") == "Microsoft.NETCore.App" and
                            f.get("version") == "10.0.15"
                            for f in options.get("includedFrameworks", [])),
                        f"Bundled .NET 10.0.15 not declared: {config}")
            require("Templates/OtpWidgetTemplate.json" in names,
                    f"Missing widget template: {label}")
            for binary in ("Otpeek.exe", "otpeek_ffi.dll", "Otpeek.Widget.exe", "coreclr.dll", "clrjit.dll", "hostfxr.dll", "hostpolicy.dll"):
                require(pe_machine(archive.read(binary)) == machine, f"PE architecture mismatch: {binary}")
            require(any(e.get("Category") == "windows.comServer" for e in manifest.iter()),
                    f"Missing widget COM registration: {label}")
            require(any(e.get("Name") == "com.microsoft.windows.widgets" for e in manifest.iter()),
                    f"Missing widget provider registration: {label}")
            found.append(arch)

    suffix = path.suffix.lower()
    kinds = {".msixupload": "upload", ".appxupload": "upload", ".msixbundle": "bundle",
             ".appxbundle": "bundle", ".msix": "package", ".appx": "package"}
    require(suffix in kinds, "Unsupported package extension")
    visit(path.read_bytes(), path.name, kinds[suffix])
    require(set(found) == set(architectures), "Application architecture set differs from expected")
    require(len(found) == len(set(found)), "Duplicate application architecture")
    require(set(map(str, required_resource_scales)) <= resource_scales,
            "Missing required scale resources")
    return {"payloadChecks": "PASS", "architectures": found,
            "previewIdentity": preview_identity, "partnerCenterIdentityVerified": False,
            "nativeIntegrityChecked": False, "wackChecked": False,
            "signedOrSubmitted": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--publisher", required=True)
    parser.add_argument("--display-name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--architecture", action="append", choices=["x64", "arm64", "x86"], required=True)
    parser.add_argument("--preview-identity", action="store_true",
                        help="Allow local placeholder identity for payload QA only; not a submission approval")
    parser.add_argument("--require-resource-scale", action="append", type=int, default=[],
                        help="Require a scale qualifier in the actual embedded package manifests")
    args = parser.parse_args()
    try:
        result = verify(args.artifact, args.name, args.publisher, args.display_name, args.version,
                        args.architecture, args.preview_identity, args.require_resource_scale)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, ET.ParseError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
