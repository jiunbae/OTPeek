# Windows dependency notice sources

`overrides.json` records the upstream URLs, commits and SHA-256 of notice files
missing from restored package roots. The H.NotifyIcon commit comes from NuGet
repository metadata; the UniFFI commit comes from the registry crate's
`.cargo_vcs_info.json`. ZXing's Apache license text is preserved from its core
0.16.11 release commit. This does not assert that the separate binding package
has identical source code.

The distributable collection is in
`windows/Otpeek.App/Assets/ThirdPartyNotices`. It preserves restored NuGet/Rust
notice originals, package provenance and unmodified MPL source crate archives.
The graph conservatively includes build dependencies. A package's presence in
the inventory is not a claim that all its code is in the executable. Windows SDK
BuildTools are marked as build tooling, rather than assigned an invented license.

To regenerate after dependency changes, first build/restore the existing pinned
projects, then collect metadata without a build, install or network operation:

```powershell
./windows/scripts/notice-inventory.ps1 -OutputPath <ignored>/nuget-inventory.json
cargo tree --manifest-path core/Cargo.toml --locked --offline -p otpeek-ffi `
  --target x86_64-pc-windows-msvc --edges normal,build --prefix none `
  --format '{p}|{l}' | Set-Content -Encoding UTF8 <ignored>/cargo-tree.txt
python windows/scripts/collect-release-notices.py `
  --nuget-inventory <ignored>/nuget-inventory.json `
  --cargo-tree <ignored>/cargo-tree.txt `
  --cargo-registry "$env:USERPROFILE/.cargo/registry/src" `
  --overrides windows/third-party-notice-sources/overrides.json `
  --output <new-empty-output-directory>
```

The Python 3.10+ standard-library collector refuses to overwrite an existing
output. Review the new output before replacing generated assets; preserve
original text bytes. Verify MPL source archive hashes against the package
checksums in `core/Cargo.lock`. Repackage and check the actual upload envelope,
notice hashes and functional binary hashes after an asset change.
