# Read restored app/widget package metadata only. No restore, install or network.
param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidateSet('win-x64', 'win-arm64', 'win-x86')]
    [string[]]$RuntimeIdentifiers = @('win-x64')
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '../..')
$seen = @{}
foreach ($project in @('Otpeek.App', 'Otpeek.Widget')) {
    $assets = Get-Content (Join-Path $root "windows/$project/obj/project.assets.json") -Raw | ConvertFrom-Json
    $packageRoot = @($assets.packageFolders.PSObject.Properties.Name)[0]
    $packages = @($assets.libraries.PSObject.Properties |
        Where-Object { $_.Value.type -eq 'package' } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.Value.path } })
    # Self-contained .NET runtime packs are download dependencies, not libraries.
    # Include the selected shipping RIDs so their original notices are not lost.
    foreach ($framework in $assets.project.frameworks.PSObject.Properties.Value) {
        foreach ($dependency in $framework.downloadDependencies) {
            if ($RuntimeIdentifiers | Where-Object { $dependency.name -eq "Microsoft.NETCore.App.Runtime.$_" }) {
                $version = $dependency.version -replace '^\[([^,]+),.*$', '$1'
                $packages += [pscustomobject]@{
                    Name = "$($dependency.name)/$version"
                    Path = "$($dependency.name.ToLowerInvariant())/$version"
                }
            }
        }
    }
    foreach ($lib in $packages) {
        if ($seen.ContainsKey($lib.Name)) { continue }
        $path = Join-Path $packageRoot $lib.Path
        $spec = Get-ChildItem $path -Filter *.nuspec | Select-Object -First 1
        [xml]$xml = Get-Content $spec.FullName -Raw
        $metadata = $xml.SelectSingleNode('/*[local-name()="package"]/*[local-name()="metadata"]')
        $license = $metadata.SelectSingleNode('*[local-name()="license"]')
        $licenseUrl = $metadata.SelectSingleNode('*[local-name()="licenseUrl"]')
        $files = @(Get-ChildItem $path -File |
            Where-Object { $_.Name -match '(?i)license|notice|copying' } | Select-Object -ExpandProperty Name)
        $seen[$lib.Name] = [ordered]@{
            id = $lib.Name; path = $path
            licenseType = if ($license) { $license.type } else { $null }
            license = if ($license) { $license.InnerText } else { $null }
            licenseUrl = if ($licenseUrl) { $licenseUrl.InnerText } else { $null }
            rootLicenseFiles = $files
        }
    }
}
@($seen.Values | Sort-Object id) | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $OutputPath
