"""Synthetic ZIP/PE fixtures only; never opens an installed application or vault."""

import importlib.util
import io
import json
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("store_check", Path(__file__).with_name("verify-store-package.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def zipped(entries):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return stream.getvalue()


def pe(machine=0x8664):
    data = bytearray(96)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 64)
    data[64:68] = b"PE\0\0"
    struct.pack_into("<H", data, 68, machine)
    return bytes(data)


def payload(name="Example.OTPeek", missing=None, machine=0x8664, private=False,
            external_runtime=False, runtime_machine=0x8664, scale=None, runtime_version="10.0.15"):
    manifest = f'''<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
    <Identity Name="{name}" Publisher="CN=Fixture" Version="2.0.1.0" ProcessorArchitecture="x64"/>
    <Properties><PublisherDisplayName>Fixture Publisher</PublisherDisplayName></Properties>
    <Resources>{f'<Resource Scale="{scale}"/>' if scale else ''}</Resources>
    <Applications><Application><Extensions><Extension Category="windows.comServer"/>
    <Extension><AppExtension Name="com.microsoft.windows.widgets"/></Extension>
    </Extensions></Application></Applications></Package>'''
    runtime = {"runtimeOptions": {"includedFrameworks": [{"name": "Microsoft.NETCore.App", "version": runtime_version}]}}
    if external_runtime:
        runtime = {"runtimeOptions": {"framework": {"name": "Microsoft.NETCore.App", "version": "10.0.15"}}}
    entries = {"AppxManifest.xml": manifest, "Otpeek.exe": pe(), "otpeek_ffi.dll": pe(machine),
               "Otpeek.Widget.exe": pe(), "Otpeek.Widget.dll": b"fixture",
               "Otpeek.Widget.deps.json": "{}", "Otpeek.Widget.runtimeconfig.json": json.dumps(runtime),
               "Otpeek.runtimeconfig.json": json.dumps(runtime),
               "coreclr.dll": pe(runtime_machine), "clrjit.dll": pe(), "hostfxr.dll": pe(),
               "hostpolicy.dll": pe(), "System.Private.CoreLib.dll": pe(),
               "Templates/OtpWidgetTemplate.json": "{}", "Templates/decoy.json": "{}"}
    if missing:
        entries.pop(missing)
    if private:
        entries["fixture.pfx"] = b"public synthetic fixture only"
    return zipped(entries)


def upload(package):
    manifest = '''<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle">
    <Identity Name="Example.OTPeek" Publisher="CN=Fixture" Version="2026.1.1.0"/>
    <Packages><Package FileName="fixture_x64.msix"/></Packages></Bundle>'''
    bundle = zipped({"AppxMetadata/AppxBundleManifest.xml": manifest, "fixture_x64.msix": package})
    return zipped({"fixture.msixbundle": bundle})


class StorePackageFixtures(unittest.TestCase):
    def validate(self, data, **overrides):
        with tempfile.TemporaryDirectory(prefix="otpeek-store-fixture-") as directory:
            path = Path(directory) / "fixture.msixupload"
            path.write_bytes(data)
            args = dict(name="Example.OTPeek", publisher="CN=Fixture", display_name="Fixture Publisher",
                        version="2.0.1.0", architectures=["x64"])
            args.update(overrides)
            return check.verify(path, **args)

    def test_valid_nested_upload_reports_structural_checks_only(self):
        result = self.validate(upload(payload()))
        self.assertEqual(result["payloadChecks"], "PASS")
        self.assertFalse(result["nativeIntegrityChecked"])
        self.assertFalse(result["wackChecked"])

    def test_stale_inner_package_rejected_despite_correct_bundle_identity(self):
        with self.assertRaisesRegex(check.PackageError, "Identity mismatch"):
            self.validate(upload(payload(name="Old.Package")))

    def test_missing_native_core_rejected(self):
        with self.assertRaisesRegex(check.PackageError, "Missing app/core/widget"):
            self.validate(upload(payload(missing="otpeek_ffi.dll")))

    def test_unrelated_template_json_does_not_mask_missing_widget_card(self):
        with self.assertRaisesRegex(check.PackageError, "Missing widget template"):
            self.validate(upload(payload(missing="Templates/OtpWidgetTemplate.json")))

    def test_wrong_native_architecture_rejected(self):
        with self.assertRaisesRegex(check.PackageError, "PE architecture mismatch"):
            self.validate(upload(payload(machine=0xAA64)))

    def test_missing_dotnet_runtime_rejected(self):
        with self.assertRaisesRegex(check.PackageError, "Missing bundled .NET runtime"):
            self.validate(upload(payload(missing="coreclr.dll")))

    def test_external_dotnet_dependency_rejected(self):
        with self.assertRaisesRegex(check.PackageError, "External .NET framework required"):
            self.validate(upload(payload(external_runtime=True)))

    def test_unsupported_or_stale_runtime_rejected(self):
        for version in ("8.0.34", "9.0.23", "10.0.14", "11.0.0"):
            with self.subTest(version=version):
                with self.assertRaisesRegex(check.PackageError, "Bundled .NET 10.0.15"):
                    self.validate(upload(payload(runtime_version=version)))

    def test_old_widget_runtime_rejected_with_current_app_runtime(self):
        with zipfile.ZipFile(io.BytesIO(payload())) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        config = {"runtimeOptions": {"includedFrameworks": [
            {"name": "Microsoft.NETCore.App", "version": "8.0.34"}]}}
        entries["Otpeek.Widget.runtimeconfig.json"] = json.dumps(config)
        with self.assertRaisesRegex(check.PackageError, "Otpeek.Widget.runtimeconfig.json"):
            self.validate(upload(zipped(entries)))

    def test_wrong_dotnet_runtime_architecture_rejected(self):
        with self.assertRaisesRegex(check.PackageError, "PE architecture mismatch"):
            self.validate(upload(payload(runtime_machine=0xAA64)))

    def test_private_key_filename_rejected(self):
        with self.assertRaisesRegex(check.PackageError, "Private-key file"):
            self.validate(upload(payload(private=True)))

    def test_placeholder_identity_rejected(self):
        with self.assertRaisesRegex(check.PackageError, "Placeholder"):
            self.validate(upload(payload()), name="Otpeek")

    def test_unbuilt_architecture_rejected(self):
        with self.assertRaisesRegex(check.PackageError, "architecture set"):
            self.validate(upload(payload()), architectures=["x64", "arm64"])

    def test_wrong_publisher_display_name_rejected(self):
        with self.assertRaisesRegex(check.PackageError, "display name mismatch"):
            self.validate(upload(payload()), display_name="Other Publisher")

    def test_explicit_preview_never_reports_verified_store_identity(self):
        result = self.validate(upload(payload()), preview_identity=True)
        self.assertTrue(result["previewIdentity"])
        self.assertFalse(result["partnerCenterIdentityVerified"])

    def test_incremental_bundle_missing_scale_resource_rejected(self):
        with self.assertRaisesRegex(check.PackageError, "Missing required scale resources"):
            self.validate(upload(payload()), required_resource_scales=[125])

    def test_requested_scale_present_in_actual_package(self):
        result = self.validate(upload(payload(scale=125)), required_resource_scales=[125])
        self.assertEqual(result["payloadChecks"], "PASS")


if __name__ == "__main__":
    unittest.main()
