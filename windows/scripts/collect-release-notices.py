"""Collect restored dependency notice originals without installs, builds or network.

Inputs are the actual app/widget NuGet inventory and the Windows FFI normal/build
dependency tree. This intentionally includes build dependencies conservatively;
it is provenance, not a statement that every listed package ships as runtime code.
"""

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nuget-inventory", type=Path, required=True)
    parser.add_argument("--cargo-tree", type=Path, required=True)
    parser.add_argument("--cargo-registry", type=Path, required=True)
    parser.add_argument("--overrides", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Output exists; refusing to overwrite source or prior notices")
    override = json.loads(args.overrides.read_text(encoding="utf-8-sig"))
    collected = {}
    source_archives = {}
    records = []
    missing = []

    def add_file(path, source):
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        collected.setdefault(digest, data)
        return {"originalFile": path.name, "source": source, "sha256": digest,
                "file": "texts/" + digest + ".txt"}

    for item in json.loads(args.nuget_inventory.read_text(encoding="utf-8-sig")):
        root = Path(item["path"])
        files = [root / f for f in item["rootLicenseFiles"]]
        if item["licenseType"] == "file":
            declared = (root / item["license"]).resolve()
            if not declared.is_relative_to(root.resolve()):
                raise ValueError("License file escapes NuGet package")
            if declared.is_file() and declared not in [p.resolve() for p in files]:
                files.append(declared)
        notices = [add_file(p, "NuGet package " + item["id"]) for p in files]
        for name in override["packages"].get(item["id"], []):
            source = override["sources"][name]
            path = args.overrides.parent / name
            if hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
                raise ValueError("Pinned upstream notice hash mismatch")
            notices.append(add_file(path, source["url"]))
        build_only = item["id"].split('/')[0] in {
            "Microsoft.Windows.SDK.BuildTools", "Microsoft.Windows.SDK.BuildTools.MSIX"}
        if not notices and not build_only:
            missing.append("NuGet " + item["id"])
        records.append({"ecosystem": "NuGet", "package": item["id"], "license": item["license"],
                        "buildToolOnly": build_only, "notices": notices})

    packages = {(m[0], m[1]): re.sub(r"\s+\(\*\)$", "", m[2]).strip() for m in
                re.findall(r"^([\w-]+) v([^\s|]+)[^|\r\n]*\|([^\r\n]*)",
                           args.cargo_tree.read_text(encoding="utf-8-sig"), re.M)}
    if not packages:
        raise ValueError("Expected cargo tree --format '{p}|{l}'")
    for (name, version), license_expression in sorted(packages.items()):
        if name.startswith("otpeek-"):
            continue
        roots = list(args.cargo_registry.glob("*/" + name + "-" + version))
        if len(roots) != 1:
            raise ValueError("Expected one restored Rust crate: " + name + " " + version)
        root = roots[0]
        # Cargo has already supplied parsed SPDX metadata. Only a normalized local
        # license-file path is read here; no TOML parser or Python upgrade needed.
        manifest = (root / "Cargo.toml").read_text()
        package_section = manifest.split('[package]', 1)[1].split('\n[', 1)[0]
        declared_path = re.search(r'^license-file\s*=\s*"([^"\n]+)"', package_section, re.M)
        files = [p for p in root.iterdir() if p.is_file() and
                 p.name.lower().startswith(("license", "copying", "notice", "copyright"))]
        if declared_path:
            declared = (root / declared_path[1]).resolve()
            if not declared.is_relative_to(root.resolve()):
                raise ValueError("License file escapes Rust package")
            if declared.is_file() and declared not in [p.resolve() for p in files]:
                files.append(declared)
        for folder in root.iterdir():
            if folder.is_dir() and folder.name.lower() in {"licenses", "licences"}:
                files.extend(p for p in folder.rglob('*') if p.is_file())
        notices = [add_file(p, "Rust registry crate " + name + " " + version) for p in sorted(set(files))]
        for filename in override["packages"].get("Rust:" + name + "/" + version, []):
            source = override["sources"][filename]
            path = args.overrides.parent / filename
            if hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
                raise ValueError("Pinned upstream Rust notice hash mismatch")
            notices.append(add_file(path, source["url"]))
        if not notices:
            missing.append("Rust " + name + " " + version)
        record = {"ecosystem": "Rust", "package": name + "/" + version,
                  "license": license_expression, "notices": notices}
        if "MPL-2.0" in license_expression:
            archive = args.cargo_registry.parent / 'cache' / root.parent.name / (name + '-' + version + '.crate')
            if not archive.is_file():
                raise ValueError("Missing original MPL crate archive: " + name)
            data = archive.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            source_archives[archive.name] = data
            record["sourceArchive"] = {"file": "sources/" + archive.name, "sha256": digest,
                                       "url": f"https://crates.io/api/v1/crates/{name}/{version}/download"}
        records.append(record)
    if missing:
        raise ValueError("Missing original notice sources: " + ", ".join(missing))
    args.output.mkdir(parents=True)
    try:
        (args.output / "texts").mkdir()
        for digest, data in collected.items():
            (args.output / "texts" / (digest + ".txt")).write_bytes(data)
        (args.output / "sources").mkdir()
        for name, data in source_archives.items():
            (args.output / "sources" / name).write_bytes(data)
        index = {"scope": "Restored Windows app/widget NuGet packages and otpeek-ffi Windows normal/build graph; includes tooling conservatively",
                 "packages": records, "distinctNoticeTexts": len(collected),
                 "unmodifiedMplSourceArchives": len(source_archives)}
        (args.output / "index.json").write_text(json.dumps(index, indent=2) + '\n', encoding="utf-8")
        text = ["OTPeek third-party dependency notices", "", index["scope"], "",
                "Original notice files are preserved byte-for-byte under texts/.",
                "index.json maps package versions and source provenance to SHA-256 files.",
                "Original unmodified MPL crate source archives are under sources/.",
                "Package license identifiers do not replace the original terms.", ""]
        text.extend(f"{r['ecosystem']} {r['package']} | {r['license'] or 'see package terms'}" for r in records)
        (args.output / "README.txt").write_text('\n'.join(text) + '\n', encoding="utf-8")
    except Exception:
        shutil.rmtree(args.output)  # Only this invocation's newly created output.
        raise
    print(json.dumps({"packages": len(records), "distinctNoticeTexts": len(collected),
                      "unmodifiedMplSourceArchives": len(source_archives), "missingOriginals": 0}))


if __name__ == "__main__":
    main()
