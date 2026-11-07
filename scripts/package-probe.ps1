# Zips the probe for volunteers: dist\KBSProbe-<version>.zip, with the
# KBSProbe folder at its root, ready to unzip into Interface\AddOns.
$ErrorActionPreference = 'Stop'

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$source = Join-Path $projectRoot 'probe\KBSProbe'
$dist = Join-Path $projectRoot 'dist'

$toc = Get-Content -LiteralPath (Join-Path $source 'KBSProbe.toc')
$version = ($toc | Where-Object { $_ -match '^## Version:\s*(.+)$' } | Select-Object -First 1) -replace '^## Version:\s*', ''
if (-not $version) { throw 'No ## Version line in KBSProbe.toc' }

New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist ("KBSProbe-{0}.zip" -f $version.Trim())
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $source -DestinationPath $zip

Write-Host "Packaged -> $zip"
