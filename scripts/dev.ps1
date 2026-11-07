param(
    [string[]]$WowAddOnsPath,
    [string[]]$Addon = @('KBSProbe')
)

$ErrorActionPreference = 'Stop'

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

# Where each addon of this repo lives.
$sources = @{
    'KBSProbe'        = Join-Path $projectRoot 'probe\KBSProbe'
    'KilledBySavages' = Join-Path $projectRoot 'addon\KilledBySavages'
}

# Personal machine paths never live in source control. Provide yours via:
#  - the -WowAddOnsPath parameter (one or more paths),
#  - the KBS_WOW_ADDONS_PATH environment variable (';'-separated), or
#  - a local scripts\dev.local.ps1 file (gitignored) that sets $WowAddOnsPaths
#    (array) or $WowAddOnsPath (single string).
$targets = @()
if ($WowAddOnsPath) { $targets = @($WowAddOnsPath) }

if (-not $targets) {
    $localOverride = Join-Path $PSScriptRoot 'dev.local.ps1'
    if (Test-Path -LiteralPath $localOverride) {
        . $localOverride
        if ($WowAddOnsPaths) { $targets = @($WowAddOnsPaths) }
        elseif ($WowAddOnsPath) { $targets = @($WowAddOnsPath) }
    }
}

if (-not $targets -and $env:KBS_WOW_ADDONS_PATH) {
    $targets = $env:KBS_WOW_ADDONS_PATH -split ';' | Where-Object { $_ }
}

if (-not $targets) {
    $targets = @(
        "${env:ProgramFiles(x86)}\World of Warcraft\_forever_\Interface\AddOns",
        "$env:ProgramFiles\World of Warcraft\_forever_\Interface\AddOns"
    ) | Where-Object { Test-Path -LiteralPath $_ }
}

if (-not $targets) {
    throw "No WoW AddOns folder found. Pass -WowAddOnsPath, set KBS_WOW_ADDONS_PATH, or create scripts\dev.local.ps1 setting `$WowAddOnsPaths."
}

# Only ever deploy into a real WoW AddOns folder, whatever the flavour.
$flavourPattern = 'World of Warcraft\\_[^\\]+_\\Interface\\AddOns$'
$deployed = 0

foreach ($name in $Addon) {
    $source = $sources[$name]
    if (-not $source) { throw "Unknown addon '$name'. Known: $($sources.Keys -join ', ')" }
    if (-not (Test-Path -LiteralPath (Join-Path $source "$name.toc"))) {
        throw "TOC file not found in addon source: $source"
    }

    foreach ($path in $targets) {
        if (-not $path) { continue }
        if (-not (Test-Path -LiteralPath $path)) {
            throw "AddOns folder not found: $path"
        }

        $resolved = (Resolve-Path -LiteralPath $path).Path.TrimEnd('\')
        if ($resolved -notmatch $flavourPattern) {
            throw "Refusing to deploy outside a WoW AddOns folder: $resolved"
        }

        $destination = Join-Path $resolved $name
        New-Item -ItemType Directory -Force -Path $destination | Out-Null

        robocopy $source $destination /MIR /NFL /NDL /NJH /NJS /NP /XF *.zip | Out-Host
        $code = $LASTEXITCODE
        if ($code -gt 7) {
            throw "robocopy failed with exit code $code (target: $destination)"
        }

        Write-Host "DEV deploy complete -> $destination"
        $deployed++
    }
}

Write-Host "Deployed $deployed time(s). A new addon needs a full game restart; updates only need /reload."
exit 0
